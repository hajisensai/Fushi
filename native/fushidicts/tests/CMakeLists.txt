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
add_hoshi_test(freq_pitch_merge_query_test freq_pitch_merge_query_test.cpp)
# BUG-1304: the two tests above drive DictionaryQuery::query(); this one drives
# Lookup::lookup(), the path the app actually calls and the one whose freq/pitch
# enrichment moved out of query_raw().
add_hoshi_test(lookup_freq_pitch_enrichment_test lookup_freq_pitch_enrichment_test.cpp)
# BUG-1303: damaged hash.table must not hang (unbounded probe) or read OOB.
# A hang here is a frozen app, so cap the case well under the ctest default.
add_hoshi_test(hash_truncated_table_guard_test hash_truncated_table_guard_test.cpp)
set_tests_properties(hash_truncated_table_guard_test PROPERTIES TIMEOUT 60)
add_hoshi_test(ipa_import_query_test ipa_import_query_test.cpp)
# Simple dicts (MDX/StarDict/DSL) store rules="*" so filter_by_pos keeps them
# for inflected-form lookups; pins pos_to_conditions("*")==~0 + the stored rule.
add_hoshi_test(simple_dict_deinflection_test simple_dict_deinflection_test.cpp)

# --- TODO-892: malformed-DEFLATE / null-decompressor / breadcrumb guards ---
# zip_malformed_deflate_test includes <libdeflate.h> (to forge a real deflate
# stream) + "zip/zip.hpp" + the public importer header. hoshidicts links
# libdeflate_static PRIVATE, so its include dir is not propagated transitively;
# add HOSHI_SRC (for zip/zip.hpp) and the libdeflate dir explicitly.
add_hoshi_test(zip_malformed_deflate_test zip_malformed_deflate_test.cpp
    "${HOSHI_SRC}"
    "${HOSHI_ROOT}/hoshidicts_external/libdeflate")
# BUG-927: a legitimate high-compression yomitan bank (ratio > the old 1100:1
# cap) must NOT be rejected; the guard is now an absolute-size bound. Pins the
# now-public zip_uncompressed_size_in_range() boundary + an end-to-end inflate.
add_hoshi_test(zip_high_ratio_bank_test zip_high_ratio_bank_test.cpp
    "${HOSHI_SRC}"
    "${HOSHI_ROOT}/hoshidicts_external/libdeflate")
# BUG-727: MDX Encrypted="2" key-block-info must be unscrambled (RIPEMD-128 +
# rolling XOR) before inflate. Builds a self-contained encrypted MDX fixture
# and asserts the reader recovers its entries. Needs mdx_reader.hpp (mdx/ is an
# internal subdir) and libdeflate (to compress the fixture's blocks).
add_hoshi_test(mdx_encrypted_keyinfo_test mdx_encrypted_keyinfo_test.cpp
    "${HOSHI_SRC}/mdx"
    "${HOSHI_ROOT}/hoshidicts_external/libdeflate")
# BUG-729 Phase B: import_mdx inlines a sibling <base>.css as the dict styles.css.
# Builds a real on-disk MDX (mdx_fixture.hpp) + sibling .css and asserts it lands.
add_hoshi_test(simple_dict_css_test simple_dict_css_test.cpp
    "${HOSHI_ROOT}/hoshidicts_external/libdeflate")
# Phase A: MDD (MDX media companion) parses byte-exact and auto-mounts into the
# dict as media.bin/idx; get_media_file returns the bytes by normalized path.
add_hoshi_test(mdd_media_import_test mdd_media_import_test.cpp
    "${HOSHI_SRC}/mdx"
    "${HOSHI_ROOT}/hoshidicts_external/libdeflate")
# import_breadcrumb_test includes "util/import_breadcrumb.hpp" rooted at
# hoshidicts_src/.
add_hoshi_test(import_breadcrumb_test import_breadcrumb_test.cpp
    "${HOSHI_SRC}")
# Source-scan guard: walk hoshidicts_src/ and require a null check after every
# libdeflate_alloc_decompressor(). The source root is passed on argv so the
# test does not depend on the runtime cwd.
add_executable(decompressor_null_guard_test
    "${CMAKE_CURRENT_SOURCE_DIR}/decompressor_null_guard_test.cpp")
if(MSVC)
  target_compile_options(decompressor_null_guard_test PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
endif()
add_test(NAME decompressor_null_guard_test
         COMMAND decompressor_null_guard_test "${HOSHI_SRC}")

# win_utf8_import_test and dict_name_lifetime_test take external dictionary
# directories / pre-built zips on argv (no self-contained fixture), so they are
# NOT auto-registered as no-arg ctest cases. dict_name_uaf_e2e_test below is the
# self-contained, fixture-driven successor that covers the same BUG-052 path.
