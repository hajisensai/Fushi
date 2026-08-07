@echo off
REM Build + run the word-boundary scan-candidate guard test on Windows.
REM Pure in-memory (no DB/FFI); only depends on utfcpp (header-only).
REM Do NOT redirect vcvars output to nul (it breaks subsequent cl with 9009).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "%~dp0\.."
REM Include dirs mirror the real CMake lib build (NO -I hoshidicts_src): the .cpp
REM self-includes its own-dir header bare; only point at scan/ + utfcpp.
cl /nologo /std:c++latest /EHsc /utf-8 /MD /I hoshidicts_src\scan /I hoshidicts_external\utfcpp\source tests\word_scan_test.cpp hoshidicts_src\scan\word_scan.cpp /Fe:tests\word_scan_test.exe /Fo:tests\
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
tests\word_scan_test.exe
exit /b %errorlevel%
