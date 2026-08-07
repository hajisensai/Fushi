@echo off
REM Build + run the per-entry ZIP64 central-directory guard test on Windows.
REM Do NOT redirect vcvars output to nul (it breaks subsequent cl with 9009).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "%~dp0\.."
cl /nologo /std:c++latest /EHsc /utf-8 /MD /I fushidicts_src /I fushidicts_external\libdeflate tests\zip64_central_dir_test.cpp fushidicts_src\zip\zip.cpp fushidicts_src\memory\memory.cpp fushidicts_external\libdeflate\lib\deflate_decompress.c fushidicts_external\libdeflate\lib\utils.c fushidicts_external\libdeflate\lib\adler32.c fushidicts_external\libdeflate\lib\crc32.c fushidicts_external\libdeflate\lib\x86\cpu_features.c /Fe:tests\zip64_central_dir_test.exe /Fo:tests\
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
tests\zip64_central_dir_test.exe
exit /b %errorlevel%
