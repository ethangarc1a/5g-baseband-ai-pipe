import os
import subprocess
import sys

# Your exact AMD Vivado 2026.1 bin directory
VIVADO_BIN = r"C:\AMDDesignTools\2026.1\Vivado\bin"

# Prepend Vivado bin to PATH for this Python session so xvlog, xelab, and xsim are found
os.environ["PATH"] = VIVADO_BIN + os.pathsep + os.environ.get("PATH", "")

# Pass "--gui" when running `python run_sim.py --gui` to open the Vivado waveform window
use_gui = "--gui" in sys.argv
xsim_cmd = ["xsim", "nr_ai_sim", "--gui"] if use_gui else ["xsim", "nr_ai_sim", "-runall"]

STEPS = [
    ["xvlog", "--sv", "../RTL/nr_baseband_ai_pipe.sv", "../TB/tb_nr_baseband_ai_pipe.sv"],
    ["xelab", "-debug", "typical", "tb_nr_baseband_ai_pipe", "-s", "nr_ai_sim"],
    xsim_cmd
]

for cmd in STEPS:
    print(f"\n[VIVADO CLI] {' '.join(cmd)}")
    # shell=True is required on Windows because xvlog, xelab, and xsim are .bat files
    res = subprocess.run(cmd, shell=True)
    if res.returncode != 0:
        sys.exit(res.returncode)