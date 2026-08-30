"""Build BlancoVision.addon from BlancoVision_addon.cpp with MSVC. Needs the VS 2022 Build Tools
C++ workload. Pass an SDK directory to build against headers other than sdk/.

    python build.py [SDK_DIR]
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / 'BlancoVision_addon.cpp'
SDK = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'sdk'
OUT = ROOT / 'BlancoVision.addon'
OBJ = ROOT / 'build'
VCVARS = next(p for p in (
    r'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    r'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat',
) if Path(p).exists())

OBJ.mkdir(exist_ok=True)
bat = OBJ / 'build.bat'
# forward slash on /Fo: a trailing backslash inside quotes escapes the quote
bat.write_text('@echo off\ncall "' + VCVARS + '" >nul\n'
               f'cl /nologo /std:c++17 /O2 /EHsc /W3 /LD "/I{SDK}" "/Fo{OBJ}/" '
               f'"{SRC}" "/Fe:{OUT}" /link /DLL "/IMPLIB:{OBJ / "BlancoVision.lib"}"\n')
subprocess.check_call(['cmd', '/d', '/c', str(bat)])  # /d skips cmd AutoRun
print(f'{OUT} ({OUT.stat().st_size} bytes)')
