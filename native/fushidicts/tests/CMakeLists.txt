# Unified native e2e/guard harness for the fushidicts C++ engine (TODO-578).
#
# Until now the tests under native/fushidicts/tests/ were each built by hand via
# a per-test run_*.bat; the root CMakeLists never aggregated them, so CI never
# ran a single native test. This file registers every test as a ctest case that
# links the *real* fushidicts static library (add_subdirectory of the engine,
# exactly like the production build pulls in glaze / zstd / libdeflate /
# unordered_dense). One `ctest` run gates them all on Linux/macOS/Windows.
#
# Configure + run (Linux/macOS, C++23 needs g++-14 or AppleClang):
#   cmake -S native/fushidicts/tests -B <build> -G Ninja
#   ctest --test-dir <build> --output-on-failure
# Windows: tests/run_all.bat (drives vcvars64 + this CMakeLists + ctest).
#
# The legacy run_*.bat scripts are kept untouched as a manual fallback.
cmake_minimum_required(VERSION 3.22.1)
project(fushidicts_tests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Reuse the real fushidicts static library (and its bundled static deps) exactly
# as the production FFI/JNI shared libraries link it. `${FUSHI_ROOT}` is the
# engine root one level up from tests/.
get_filename_component(FUSHI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
add_subdirectory(${FUSHI_ROOT} fushidicts_build)

enable_testing()

# Test sources self-include some headers by bare name from fushidicts_src/
# subdirs (word_scan.hpp / text_processor.hpp) or as "zip/zip.hpp" rooted at
# fushidicts_src/. The engine's static lib does not export those internal dirs
# publicly, so add them per-test below. All symbols still come from `fushidicts`.
set(FUSHI_SRC "${FUSHI_ROOT}/fushidicts_src")

# add_fushi_test(<name> <source.cpp> [extra include dirs...])
#   - links the real fushidicts static lib
#   - applies MSVC /utf-8 so the UTF-8 fixture/comment bytes survive code page
#     936 (GBK) decoding on Windows runners
#   - registers a ctest case named <name>
function(add_fushi_test name source)
  add_executable(${name} "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
  target_link_libraries(${name} PRIVATE fushidicts)
  target_include_directories(${name} PRIVATE ${ARGN})
  if(MSVC)
    target_compile_options(${name} PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
  endif()
  add_test(NAME ${name} COMMAND ${name})
endfunction()

# --- Pure in-memory guards (no import/query; header-only or single subsystem) ---
# word_scan / text_processor include their header bare -> point at the subdir.
add_fushi_test(word_scan_test word_scan_test.cpp
    "${FUSHI_SRC}/scan"
    "${FUSHI_ROOT}/fushidicts_external/utfcpp/source")
add_fushi_test(text_processor_test text_processor_test.cpp
    "${FUSHI_SRC}/text_processor"
    "${FUSHI_ROOT}/fushidicts_external/utfcpp/source")
# zip64 includes "zip/zip.hpp" -> root at fushidicts_src/.
add_fushi_test(zip64_central_dir_test zip64_central_dir_test.cpp
    "${FUSHI_SRC}")

# --- import + query e2e (include "fushidicts/<x>.hpp" from the public include) ---
# The public include dir is already PUBLIC on the fushidicts target, so these
# need no extra include dirs.
add_fushi_test(kanji_import_query_test kanji_import_query_test.cpp)
add_fushi_test(dict_name_uaf_e2e_test dict_name_uaf_e2e_test.cpp)
add_fushi_test(media_import_query_test media_import_query_test.cpp)
add_fushi_test(freq_pitch_import_query_test freq_pitch_import_query_test.cpp)
add_fushi_test(freq_pitch_merge_query_test freq_pitch_merge_query_test.cpp)
# BUG-1304: the two tests above drive DictionaryQuery::query(); this one drives
# Lookup::lookup(), the path the app actually calls and the one whose freq/pitch
# enrichment moved out of query_raw().
add_fushi_test(lookup_freq_pitch_enrichment_test lookup_freq_pitch_enrichment_test.cpp)
# BUG-1303: damaged hash.table must not hang (unbounded probe) or read OOB.
# A hang here is a frozen app, so cap the case well under the ctest default.
add_fushi_test(hash_truncated_table_guard_test hash_truncated_table_guard_test.cpp)
set_tests_properties(hash_truncated_table_guard_test PROPERTIES TIMEOUT 60)
add_fushi_test(ipa_import_query_test ipa_import_query_test.cpp)
# Simple dicts (MDX/StarDict/DSL) store rules="*" so filter_by_pos keeps them
# for inflected-form lookups; pins pos_to_conditions("*")==~0 + the stored rule.
add_fushi_test(simple_dict_deinflection_test simple_dict_deinflection_test.cpp)
# BUG-1665: an MDX @@@LINK= redirect entry (definition bytes copied from its
# lemma at import) must collapse into the lemma at lookup time, so the popup
# header / mined Anki term is the dictionary form, not the inflected surface.
add_fushi_test(mdx_redirect_lemma_lookup_test mdx_redirect_lemma_lookup_test.cpp)

# --- TODO-892: malformed-DEFLATE / null-decompressor / breadcrumb guards ---
# zip_malformed_deflate_test includes <libdeflate.h> (to forge a real deflate
# stream) + "zip/zip.hpp" + the public importer header. fushidicts links
# libdeflate_static PRIVATE, so its include dir is not propagated transitively;
# add FUSHI_SRC (for zip/zip.hpp) and the libdeflate dir explicitly.
add_fushi_test(zip_malformed_deflate_test zip_malformed_deflate_test.cpp
    "${FUSHI_SRC}"
    "${FUSHI_ROOT}/fushidicts_external/libdeflate")
# BUG-927: a legitimate high-compression yomitan bank (ratio > the old 1100:1
# cap) must NOT be rejected; the guard is now an absolute-size bound. Pins the
# now-public zip_uncompressed_size_in_range() boundary + an end-to-end inflate.
add_fushi_test(zip_high_ratio_bank_test zip_high_ratio_bank_test.cpp
    "${FUSHI_SRC}"
    "${FUSHI_ROOT}/fushidicts_external/libdeflate")
# BUG-727: MDX Encrypted="2" key-block-info must be unscrambled (RIPEMD-128 +
# rolling XOR) before inflate. Builds a self-contained encrypted MDX fixture
# and asserts the reader recovers its entries. Needs mdx_reader.hpp (mdx/ is an
# internal subdir) and libdeflate (to compress the fixture's blocks).
add_fushi_test(mdx_encrypted_keyinfo_test mdx_encrypted_keyinfo_test.cpp
    "${FUSHI_SRC}/mdx"
    "${FUSHI_ROOT}/fushidicts_external/libdeflate")
# BUG-729 Phase B: import_mdx inlines a sibling <base>.css as the dict styles.css.
# Builds a real on-disk MDX (mdx_fixture.hpp) + sibling .css and asserts it lands.
add_fushi_test(simple_dict_css_test simple_dict_css_test.cpp
    "${FUSHI_ROOT}/fushidicts_external/libdeflate")
# Phase A: MDD (MDX media companion) parses byte-exact and auto-mounts into the
# dict as media.bin/idx; get_media_file returns the bytes by normalized path.
add_fushi_test(mdd_media_import_test mdd_media_import_test.cpp
    "${FUSHI_SRC}/mdx"
    "${FUSHI_ROOT}/fushidicts_external/libdeflate")
# import_breadcrumb_test includes "util/import_breadcrumb.hpp" rooted at
# fushidicts_src/.
add_fushi_test(import_breadcrumb_test import_breadcrumb_test.cpp
    "${FUSHI_SRC}")
# Source-scan guard: walk fushidicts_src/ and require a null check after every
# libdeflate_alloc_decompressor(). The source root is passed on argv so the
# test does not depend on the runtime cwd.
add_executable(decompressor_null_guard_test
    "${CMAKE_CURRENT_SOURCE_DIR}/decompressor_null_guard_test.cpp")
if(MSVC)
  target_compile_options(decompressor_null_guard_test PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
endif()
add_test(NAME decompressor_null_guard_test
         COMMAND decompressor_null_guard_test "${FUSHI_SRC}")

# win_utf8_import_test and dict_name_lifetime_test take external dictionary
# directories / pre-built zips on argv (no self-contained fixture), so they are
# NOT auto-registered as no-arg ctest cases. dict_name_uaf_e2e_test below is the
# self-contained, fixture-driven successor that covers the same BUG-052 path.
