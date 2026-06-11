@echo off
REM Build + run the TODO-094 kanji import/query guard test on Windows via CMake.
REM Reuses the real hoshidicts static lib (glaze/zstd/libdeflate) so the test
REM exercises the production import + query paths. No external zip tool needed:
REM the test hand-rolls STORED zips in memory.
REM
REM The build tree is placed under a SHORT absolute path (%TEMP%\hoshi_kj_build)
REM because the deep worktree path + nested zstd object dirs otherwise blow past
REM CMAKE_OBJECT_PATH_MAX (250 chars) and cl emits "Cannot open compiler
REM generated file".
REM Do NOT redirect vcvars output to nul (it breaks subsequent tools with 9009).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
set "BUILD_DIR=%TEMP%\hoshi_kj_build"
cmake -S "%~dp0\kanji_import_query" -B "%BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (
  echo CMAKE CONFIGURE FAILED, retrying with NMake generator
  cmake -S "%~dp0\kanji_import_query" -B "%BUILD_DIR%" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
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
if exist "%BUILD_DIR%\kanji_import_query_test.exe" (
  "%BUILD_DIR%\kanji_import_query_test.exe"
) else (
  "%BUILD_DIR%\Release\kanji_import_query_test.exe"
)
exit /b %errorlevel%
