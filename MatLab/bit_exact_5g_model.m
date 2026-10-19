
% Qualcomm Track 3: Bit-Exact 5G Baseband FIR + AI Leaky-ReLU Golden Model

clear; clc;
N = 128;
h = int64([4096, 12288, 12288, 4096]); % Symmetric Q1.15 Taps
ai_bias_q15 = int64(2048);
ai_prelu_en = true;

% Generate Q1.15 Baseband Test Waveform with High-Amplitude Distortion Spikes
n = (0:N-1)';
x_float = 0.65 * sin(2*pi*0.05*n) + 0.25 * cos(2*pi*0.35*n);
x_q15   = int64(max(min(round(x_float * 32768), 32767), -32768));

y_q15 = zeros(N, 1, 'int64');
dline = zeros(1, 3, 'int64');

for i = 1:N
    % Folded Symmetric Pre-Add + MAC
    p0 = x_q15(i) + dline(3);
    p1 = dline(1) + dline(2);
    dline = [x_q15(i), dline(1:2)];
    
    acc     = p0 * h(1) + p1 * h(2);
    rounded = floor(double(acc + 16384) / 32768.0);
    biased  = int64(rounded) + ai_bias_q15;
    
    % Hardware Shift-Based PReLU (alpha = 0.25 for negative values)
    if ai_prelu_en && (biased < 0)
        act = floor(double(biased) / 4.0);
    else
        act = biased;
    end
    
    % Q1.15 Symmetric Saturation
    y_q15(i) = max(min(int64(act), 32767), -32768);
end
fprintf('MATLAB Bit-Exact Q1.15 Reference Complete (%d samples processed).\n', N);