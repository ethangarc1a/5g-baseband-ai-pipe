`timescale 1ns / 1ps

module nr_baseband_ai_pipe #(
    parameter int DATA_WIDTH  = 16,
    parameter int COEFF_WIDTH = 16
)(
    input  logic clk,
    input  logic rst_n,

    // MAC Port 0: High-Priority 5G URLLC Packet Stream (Strict Priority)
    input  logic s0_urllc_tvalid,
    output logic s0_urllc_tready,
    input  logic signed [DATA_WIDTH-1:0] s0_urllc_tdata,
    input  logic s0_urllc_tlast,

    // MAC Port 1: Standard 5G eMBB Packet Stream
    input  logic s1_embb_tvalid,
    output logic s1_embb_tready,
    input  logic signed [DATA_WIDTH-1:0] s1_embb_tdata,
    input  logic s1_embb_tlast,

    // AI Equalizer Hardware Configuration
    input  logic ai_prelu_en,     // 1 = Enable Leaky-ReLU non-linear correction
    input  logic signed [DATA_WIDTH-1:0] ai_bias_q15,     // Learned Q1.15 DC offset / bias weight

    // PHY Output Stream (Filtered & Equalized Baseband Symbols)
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic signed [DATA_WIDTH-1:0] m_axis_tdata,
    output logic m_axis_tlast,
    output logic m_axis_qos_id,   // 0 = URLLC, 1 = eMBB
    output logic sat_flag    // Q1.15 Saturation indicator
);

    // Global Pipeline Backpressure Enable
    logic pipe_en;
    assign pipe_en = m_axis_tready || !m_axis_tvalid;

    // STAGE 1: 5G MAC-Layer QoS Packet-Locked Arbiter (URLLC Preempts eMBB)

    typedef enum logic [1:0] {
        ARB_IDLE,
        ARB_LOCK_URLLC,
        ARB_LOCK_EMBB
    } arb_state_e;

    arb_state_e arb_state, arb_next;
    logic                         mac_vld;
    logic signed [DATA_WIDTH-1:0] mac_data;
    logic                         mac_last;
    logic                         mac_qos; // 0 = URLLC, 1 = eMBB

    always_comb begin
        arb_next = arb_state;
        case (arb_state)
            ARB_IDLE: begin
                if (s0_urllc_tvalid && !s0_urllc_tlast)
                    arb_next = ARB_LOCK_URLLC;
                else if (!s0_urllc_tvalid && s1_embb_tvalid && !s1_embb_tlast)
                    arb_next = ARB_LOCK_EMBB;
            end
            ARB_LOCK_URLLC: if (s0_urllc_tvalid && s0_urllc_tlast) arb_next = ARB_IDLE;
            ARB_LOCK_EMBB:  if (s1_embb_tvalid  && s1_embb_tlast)  arb_next = ARB_IDLE;
            default:        arb_next = ARB_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) arb_state <= ARB_IDLE;
        else if (pipe_en) arb_state <= arb_next;
    end

    // Grant decision: Port 0 (URLLC) wins whenever ARB_IDLE or locked to URLLC
    logic sel_embb;
    assign sel_embb = (arb_state == ARB_LOCK_EMBB) ||
                      ((arb_state == ARB_IDLE) && !s0_urllc_tvalid && s1_embb_tvalid);

    assign s0_urllc_tready = pipe_en && !sel_embb;
    assign s1_embb_tready  = pipe_en &&  sel_embb;

    assign mac_vld  = sel_embb ? s1_embb_tvalid : s0_urllc_tvalid;
    assign mac_data = sel_embb ? s1_embb_tdata  : s0_urllc_tdata;
    assign mac_last = sel_embb ? s1_embb_tlast  : s0_urllc_tlast;
    assign mac_qos  = sel_embb;

    
    // STAGE 2: PHY Layer 4-Tap Folded Symmetric FIR Filter (50% Multiplier Save)
    // Symmetric Q1.15 Taps: h[0]=h[3]=4096 (0.125), h[1]=h[2]=12288 (0.375)

    localparam logic signed [COEFF_WIDTH-1:0] H0 = 16'sd4096;
    localparam logic signed [COEFF_WIDTH-1:0] H1 = 16'sd12288;

    logic signed [DATA_WIDTH-1:0] dline [0:2];
    logic signed [DATA_WIDTH:0]   pre_add0, pre_add1;
    logic signed [33:0]           fir_sum_stg1;
    logic                         vld_stg1, last_stg1, qos_stg1;

    // Folded Pre-Add + Multiply-Accumulate in one clean DSP stage
    assign pre_add0 = $signed(mac_data) + $signed(dline[2]); // x[n] + x[n-3]
    assign pre_add1 = $signed(dline[0]) + $signed(dline[1]); // x[n-1] + x[n-2]

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dline[0]     <= '0;
            dline[1]     <= '0;
            dline[2]     <= '0;
            fir_sum_stg1 <= '0;
            vld_stg1     <= 1'b0;
            last_stg1    <= 1'b0;
            qos_stg1     <= 1'b0;
        end else if (pipe_en) begin
            vld_stg1  <= mac_vld;
            last_stg1 <= mac_last;
            qos_stg1  <= mac_qos;
            if (mac_vld) begin
                dline[0]     <= mac_data;
                dline[1]     <= dline[0];
                dline[2]     <= dline[1];
                fir_sum_stg1 <= (pre_add0 * H0) + (pre_add1 * H1);
            end
        end
    end

    
    // STAGE 3: Hardware AI/ML Non-Linear Equalizer (PReLU + Bias + Saturation)

    logic signed [33:0] fir_rounded;
    logic signed [17:0] ai_biased;
    logic signed [17:0] ai_activated;
    logic signed [15:0] sat_out;
    logic               sat_det;

    always_comb begin
        // 1. Q2.30 -> Q1.15 Round-Half-Up: (fir_sum + 2^14) >>> 15
        fir_rounded = (fir_sum_stg1 + 34'sd16384) >>> 15;

        // 2. Add learned neural bias weight
        ai_biased = fir_rounded[17:0] + $signed(ai_bias_q15);

        // 3. Hardware-Friendly Parametric Leaky-ReLU (PReLU):
        //    For negative values when enabled, apply alpha = 0.25 via shift: x - (x >>> 2) = 0.75*x or (x >>> 2)
        if (ai_prelu_en && (ai_biased < 0))
            ai_activated = ai_biased >>> 2; // Leaky slope alpha = 0.25 (zero extra multipliers!)
        else
            ai_activated = ai_biased;

        // 4. Symmetric Q1.15 Saturation Clamping [-32768, +32767]
        if (ai_activated > 18'sd32767) begin
            sat_out = 16'sd32767;
            sat_det = 1'b1;
        end else if (ai_activated < -18'sd32768) begin
            sat_out = -16'sd32768;
            sat_det = 1'b1;
        end else begin
            sat_out = ai_activated[15:0];
            sat_det = 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= '0;
            m_axis_tlast  <= 1'b0;
            m_axis_qos_id <= 1'b0;
            sat_flag      <= 1'b0;
        end else if (pipe_en) begin
            m_axis_tvalid <= vld_stg1;
            m_axis_tdata  <= sat_out;
            m_axis_tlast  <= last_stg1;
            m_axis_qos_id <= qos_stg1;
            sat_flag      <= vld_stg1 && sat_det;
        end
    end

endmodule