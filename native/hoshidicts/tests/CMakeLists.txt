# Unified native e2e/guard harness for the hoshidicts C++ engine (TODO-578).
#
# Until now the tests under native/hoshidicts/tests/ were each built by hand via
# a per-test run_*.bat; the root CMakeLists never aggregated them, so CI never
# ran a single native test. This file registers every test as a ctest case that
# links the *real* hoshidicts static library (add_subdirectory of the engine,
# exactly like the production build pulls in glaze / zstd / libdeflate /
# unordered_dense). One `ctest` run gates them all on Linux/macOS/Windows.
#
# Configure + run (Linux/macOS, C++23 needs g++-14 or AppleClang):
#   cmake -S native/hoshidicts/tests -B <build> -G Ninja
#   ctest --test-dir <build> --output-on-failure
# Windows: tests/run_all.bat (drives vcvars64 + this CMakeLists + ctest).
#
# The legacy run_*.bat scripts are kept untouched as a manual fallback.
cmake_minimum_required(VERSION 3.22.1)
project(hoshidicts_tests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Reuse the real hoshidicts static library (and its bundled static deps) exactly
# as the production FFI/JNI shared libraries link it. `${HOSHI_ROOT}` is the
# engine root one level up from tests/.
get_filename_component(HOSHI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
add_subdirectory(${HOSHI_ROOT} hoshidicts_build)

enable_testing()

# Test sources self-include some headers by bare name from hoshidicts_src/
# subdirs (word_scan.hpp / text_processor.hpp) or as "zip/zip.hpp" rooted at
# hoshidicts_src/. The engine's static lib does not export those internal dirs
# publicly, so add them per-test below. All symbols still come from `hoshidicts`.
set(HOSHI_SRC "${HOSHI_ROOT}/hoshidicts_src")

# add_hoshi_test(<name> <source.cpp> [extra include dirs...])
#   - links the real hoshidicts static lib
#   - applies MSVC /utf-8 so the UTF-8 fixture/comment bytes survive code page
#     936 (GBK) decoding on Windows runners
#   - registers a ctest case named <name>
function(add_hoshi_test name source)
  add_executable(${name} "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
  target_link_libraries(${name} PRIVATE hoshidicts)
  target_include_directories(${name} PRIVATE ${ARGN})
  if(MSVC)
    target_compile_options(${name} PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
  endif()
  add_test(NAME ${name} COMMAND ${name})
endfunction()

# --- Pure in-memory guards (no import/query; header-only or single subsystem) ---
# word_scan / text_processor include their header bare -> point at the subdir.
add_hoshi_test(word_scan_test word_scan_test.cpp
    "${HOSHI_SRC}/scan"
    "${HOSHI_ROOT}/hoshidicts_external/utfcpp/source")
add_hoshi_test(text_processor_test text_processor_test.cpp
    "${HOSHI_SRC}/text_processor"
    "${HOSHI_ROOT}/hoshidicts_external/utfcpp/source")
# zip64 includes "zip/zip.hpp" -> root at hoshidicts_src/.
add_hoshi_test(zip64_central_dir_test zip64_central_dir_test.cpp
    "${HOSHI_SRC}")

# --- import + query e2e (include "hoshidicts/<x>.hpp" from the public include) ---
# The public include dir is already PUBLIC on the hoshidicts target, so these
# need no extra include dirs.
add_hoshi_test(kanji_import_query_test kanji_import_query_test.cpp)
add_hoshi_test(dict_name_uaf_e2e_test dict_name_uaf_e2e_test.cpp)
add_hoshi_test(media_import_query_test media_import_query_test.cpp)
add_hoshi_test(freq_pitch_import_query_test freq_pitch_import_query_test.cpp)

# win_utf8_import_test and dict_name_lifetime_test take external dictionary
# directories / pre-built zips on argv (no self-contained fixture), so they are
# NOT auto-registered as no-arg ctest cases. dict_name_uaf_e2e_test below is the
# self-contained, fixture-driven successor that covers the same BUG-052 path.
