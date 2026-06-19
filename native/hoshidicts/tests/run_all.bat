@echo off
REM Configure + build + run the whole hoshidicts native test suite via the
REM unified CMake/ctest harness (tests\CMakeLists.txt) on Windows / MSVC.
REM
REM The build tree is placed under a SHORT absolute path (%TEMP%\hoshi_tests_build)
REM because the deep worktree path + nested zstd object dirs otherwise blow past
REM CMAKE_OBJECT_PATH_MAX (250 chars) and cl emits "Cannot open compiler
REM generated file".
REM Do NOT redirect vcvars output to nul (it breaks subsequent tools with 9009).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
set "BUILD_DIR=%TEMP%\hoshi_tests_build"
cmake -S "%~dp0." -B "%BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (
  echo CMAKE CONFIGURE FAILED, retrying with NMake generator
  cmake -S "%~dp0." -B "%BUILD_DIR%" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
  if errorlevel 1 (
    echo CMAKE CONFIGURE FAILED
    exit /b 1
  )
)
cmake --build "%BUILD_DIR%" --config Release
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
ctest --test-dir "%BUILD_DIR%" --output-on-failure -C Release
exit /b %errorlevel%
