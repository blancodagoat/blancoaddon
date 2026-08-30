"""Build BlancoVision.addon from BlancoVision_addon.cpp with MSVC. Needs the VS 2022 Build Tools
C++ workload, or any shell that already has cl.exe on PATH. Pass an SDK directory to build against
headers other than sdk/.

    python build.py [SDK_DIR]
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / 'BlancoVision_addon.cpp'
SDK = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'sdk'
OUT = ROOT / 'BlancoVision.addon'
OBJ = ROOT / 'build'

# vswhere ships at this fixed path with every VS install, the GitHub runners included, so the same
# lookup works locally and in CI. Skipped when cl.exe is already on PATH (a developer prompt).
VSWHERE = Path(r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe')
VCVARS = None
if shutil.which('cl') is None:
    root = subprocess.run([str(VSWHERE), '-latest', '-products', '*', '-property', 'installationPath',
                           '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'],
                          capture_output=True, text=True).stdout.strip() if VSWHERE.exists() else ''
    VCVARS = Path(root) / 'VC' / 'Auxiliary' / 'Build' / 'vcvars64.bat' if root else None
    if VCVARS is None or not VCVARS.exists():
        raise SystemExit('no MSVC found: install the VS 2022 Build Tools C++ workload, or run from a developer prompt')

OBJ.mkdir(exist_ok=True)
bat = OBJ / 'build.bat'
# forward slash on /Fo: a trailing backslash inside quotes escapes the quote
bat.write_text('@echo off\n' + (f'call "{VCVARS}" >nul\n' if VCVARS else '')
               + f'cl /nologo /std:c++17 /O2 /EHsc /W3 /LD "/I{SDK}" "/I{ROOT / "imgui"}" "/Fo{OBJ}/" '
               + f'"{SRC}" "/Fe:{OUT}" /link /DLL "/IMPLIB:{OBJ / "BlancoVision.lib"}"\n')
subprocess.check_call(['cmd', '/d', '/c', str(bat)])  # /d skips cmd AutoRun
print(f'{OUT} ({OUT.stat().st_size} bytes)')
