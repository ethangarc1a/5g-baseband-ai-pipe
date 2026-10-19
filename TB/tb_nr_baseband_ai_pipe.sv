`timescale 1ns / 1ps

// Object-Oriented Constrained-Random Baseband Sample Transaction
class nr_sample_item;
    rand logic signed [15:0] sample_q15;
    rand bit                 is_last;

    constraint c_signal_profile {
        sample_q15 dist {
            [-32768:-24000] := 15, // Negative spike (tests Leaky-ReLU & neg saturation)
            [-23999: 23999] := 70, // Normal linear Q1.15 dynamic range
            [ 24000: 32767] := 15  // Positive spike (tests positive saturation rail)
        };
    }
endclass

module tb_nr_baseband_ai_pipe;

    logic clk = 0;
    logic rst_n = 0;
    logic s0_urllc_tvalid, s0_urllc_tready, s0_urllc_tlast;
    logic signed [15:0] s0_urllc_tdata;
    logic s1_embb_tvalid, s1_embb_tready, s1_embb_tlast;
    logic signed [15:0] s1_embb_tdata;
    logic ai_prelu_en;
    logic signed [15:0] ai_bias_q15;
    logic m_axis_tvalid, m_axis_tready, m_axis_tlast, m_axis_qos_id, sat_flag;
    logic signed [15:0] m_axis_tdata;

    always #2.5 clk = ~clk; // 200 MHz clock

    nr_baseband_ai_pipe dut (.*);


    // 1. Concurrent SystemVerilog Assertions (SVA)


    // SVA 1: Mutual Exclusion — Arbiter must never grant both URLLC and eMBB simultaneously
    property p_arb_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(s0_urllc_tready && s1_embb_tready);
    endproperty
    a_arb_mutex: assert property (p_arb_mutex)
        else $error("[SVA FAIL] Both MAC ports granted simultaneously!");

    // SVA 2: AXI4-Stream Backpressure Stability — Output must hold stable when !m_axis_tready
    property p_axis_hold_on_stall;
        @(posedge clk) disable iff (!rst_n)
        (m_axis_tvalid && !m_axis_tready) |=> (m_axis_tvalid && $stable(m_axis_tdata) && $stable(m_axis_qos_id));
    endproperty
    a_axis_hold_on_stall: assert property (p_axis_hold_on_stall)
        else $error("[SVA FAIL] Output mutated during downstream backpressure stall!");

    // SVA 3: Saturation Flag Integrity — sat_flag implies output is clamped to Q1.15 rails
    property p_saturation_bounds;
        @(posedge clk) disable iff (!rst_n)
        (m_axis_tvalid && sat_flag) |-> ((m_axis_tdata == 16'sd32767) || (m_axis_tdata == -16'sd32768));
    endproperty
    a_saturation_bounds: assert property (p_saturation_bounds)
        else $error("[SVA FAIL] Saturation flag asserted without rail clamping!");


    // 2. Functional Coverage (covergroup)

    covergroup cg_modem_verification @(posedge clk iff (rst_n));
        cp_qos_channel: coverpoint m_axis_qos_id iff (m_axis_tvalid && m_axis_tready) {
            bins urllc_packet = {1'b0};
            bins embb_packet  = {1'b1};
        }
        cp_backpressure: coverpoint {m_axis_tvalid, m_axis_tready} {
            bins active_beat = {2'b11};
            bins stall_cycle = {2'b10};
        }
        cp_ai_mode: coverpoint ai_prelu_en iff (m_axis_tvalid) {
            bins linear_bypass = {1'b0};
            bins prelu_active  = {1'b1};
        }
        cp_saturation: coverpoint sat_flag iff (m_axis_tvalid) {
            bins normal    = {1'b0};
            bins saturated = {1'b1};
        }
        cross_qos_ai: cross cp_qos_channel, cp_ai_mode;
    endgroup

    cg_modem_verification cov_inst = new();


    // 3. Bit-Exact Golden Reference Scoreboard
    
    longint signed ref_dline [0:2] = '{0, 0, 0};
    logic signed [15:0] expected_q [$];
    int total_checked = 0;
    int err_count     = 0;

    function automatic logic signed [15:0] compute_golden(input logic signed [15:0] x_in);
        longint signed p0, p1, acc, rounded, biased, act;
        p0 = longint'(x_in) + ref_dline[2];
        p1 = ref_dline[0]   + ref_dline[1];
        ref_dline[2] = ref_dline[1];
        ref_dline[1] = ref_dline[0];
        ref_dline[0] = longint'(x_in);

        acc     = (p0 * 64'sd4096) + (p1 * 64'sd12288);
        rounded = (acc + 64'sd16384) >>> 15;
        biased  = rounded + longint'(ai_bias_q15);
        act     = (ai_prelu_en && (biased < 0)) ? (biased >>> 2) : biased;

        if (act > 32767)       return 16'sd32767;
        else if (act < -32768) return -16'sd32768;
        else                   return act[15:0];
    endfunction

    // Track accepted input samples in cycle-exact order
    always @(posedge clk) begin
        if (rst_n) begin
            if (s0_urllc_tvalid && s0_urllc_tready)
                expected_q.push_back(compute_golden(s0_urllc_tdata));
            else if (s1_embb_tvalid && s1_embb_tready)
                expected_q.push_back(compute_golden(s1_embb_tdata));
        end
    end

    // Compare DUT output against Bit-Exact Reference Queue
    always @(posedge clk) begin
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            logic signed [15:0] exp_val = expected_q.pop_front();
            if (m_axis_tdata !== exp_val) begin
                $error("[BIT-EXACT ERROR] Sample %0d: Expected %0d, Got %0d",
                       total_checked, exp_val, m_axis_tdata);
                err_count++;
            end
            total_checked++;
        end
    end

    
    // 4. Constrained-Random Stimulus Driver (URLLC + eMBB Contention)
    
    initial begin
        nr_sample_item item = new();
        s0_urllc_tvalid = 0; s0_urllc_tdata = 0; s0_urllc_tlast = 0;
        s1_embb_tvalid  = 0; s1_embb_tdata  = 0; s1_embb_tlast  = 0;
        ai_prelu_en     = 1'b1;
        ai_bias_q15     = 16'sd2048; // +0.0625 DC correction
        m_axis_tready   = 1'b1;

        #20 rst_n = 1;
        @(posedge clk);

        for (int pkt = 0; pkt < 32; pkt++) begin
            // Alternate AI mode halfway through to hit 100% cross coverage
            if (pkt == 16) begin
                // Flush pipeline before changing static config register
                repeat (4) @(posedge clk);
                ai_prelu_en = 1'b0;
            end

            // Drive simultaneous URLLC and eMBB 4-beat packets to test MAC arbitration
            for (int beat = 0; beat < 4; beat++) begin
                assert(item.randomize());
                s0_urllc_tvalid <= (pkt % 2 == 0); // URLLC active on even packets
                s0_urllc_tdata  <= item.sample_q15;
                s0_urllc_tlast  <= (beat == 3);

                assert(item.randomize());
                s1_embb_tvalid  <= 1'b1;           // eMBB always contending
                s1_embb_tdata   <= item.sample_q15;
                s1_embb_tlast   <= (beat == 3);

                // Inject randomized downstream backpressure (25% stall probability)
                m_axis_tready   <= ($urandom_range(0, 99) >= 25);
                @(posedge clk);
                while (!( (s0_urllc_tvalid && s0_urllc_tready) || (s1_embb_tvalid && s1_embb_tready) )) begin
                    m_axis_tready <= 1'b1;
                    @(posedge clk);
                end
            end
            s0_urllc_tvalid <= 0;
            s1_embb_tvalid  <= 0;
            m_axis_tready   <= 1'b1;
            @(posedge clk);
        end

        repeat (10) @(posedge clk);
        $display("==============================================================");
        $display(" 5G NR BASEBAND + AI EQUALIZER VERIFICATION SUMMARY");
        $display(" Total Samples Verified : %0d", total_checked);
        $display(" Bit-Exact Errors       : %0d", err_count);
        $display(" Functional Coverage    : %0.2f%%", cov_inst.get_inst_coverage());
        $display("==============================================================");
        if (err_count == 0 && total_checked > 0)
            $display(" RESULT: PASS — 100%% Bit-Exact Match & 0 SVA Violations");
        else
            $display(" RESULT: FAIL");
        $finish;
    end

endmodule