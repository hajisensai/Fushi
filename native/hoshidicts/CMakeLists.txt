cmake_minimum_required(VERSION 3.22.1)
cmake_policy(SET CMP0077 NEW)

project(hoshidicts_ffi LANGUAGES C CXX)

# Linux links the hoshidicts static archive and its bundled static deps into
# libhoshidicts_ffi.so. Build those objects as PIC so GNU ld can embed them.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# iOS: the Dart FFI bindings load symbols via DynamicLibrary.process(), so the
# hoshidicts symbols must live in the Runner executable image itself. We build a
# STATIC hoshidicts_ffi archive and a merged self-contained archive of it plus
# its static deps, then force_load that into Runner from the Xcode build phase.
# Everything must be PIC so it can be linked into the app executable.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(HOSHIDICTS_IOS ON)
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(CheckCXXSourceCompiles)
check_cxx_source_compiles("
#include <expected>
#ifndef __cpp_lib_expected
#error __cpp_lib_expected missing
#endif
int main() {
  std::expected<int, int> ok = 23;
  std::expected<int, int> fail = std::unexpected(1);
  return ok.value() == 23 && fail.error() == 1 ? 0 : 1;
}
" HOSHIDICTS_HAS_STD_EXPECTED)
if(NOT HOSHIDICTS_HAS_STD_EXPECTED)
  message(FATAL_ERROR
      "hoshidicts/glaze requires C++23 std::expected/std::unexpected. "
      "Select a compiler and standard library that provide <expected>.")
endif()

# MSVC: UTF-8 source/execution charset, disable min/max macros, enable C++23 features
if(MSVC)
  add_compile_options(/utf-8 /Zc:__cplusplus /permissive-)
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# Windows: export all symbols from the shared library (or use HOSHI_EXPORT selectively)
if(WIN32)
  set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS OFF)
endif()

set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "")
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "")
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "")
set(ZSTD_BUILD_STATIC ON CACHE BOOL "")

set(LIBDEFLATE_BUILD_SHARED_LIB OFF CACHE BOOL "")
set(LIBDEFLATE_BUILD_GZIP OFF CACHE BOOL "")

# utf8proc: vendored static (commit 26dbf597, v2.11.3) for NFKC normalization in
# text_processor. Suppress its install rules so they don't pollute our tree; it
# builds static (BUILD_SHARED_LIBS unset here) and defines UTF8PROC_STATIC PUBLIC
# itself, so consumers link against the static archive without DLL import attrs.
set(UTF8PROC_INSTALL OFF CACHE BOOL "")

add_subdirectory(hoshidicts_external/glaze EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/zstd EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/unordered_dense EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/libdeflate EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/utf8proc EXCLUDE_FROM_ALL)

add_library(hoshidicts STATIC
    hoshidicts_src/hash/hash.cpp
    hoshidicts_src/hash/bloom.cpp
    hoshidicts_src/importer.cpp
    hoshidicts_src/memory/memory.cpp
    hoshidicts_src/zip/zip.cpp
    hoshidicts_src/json/yomitan_parser.cpp
    hoshidicts_src/mdx/mdx_reader.cpp
    hoshidicts_src/stardict/stardict_reader.cpp
    hoshidicts_src/text_processor/text_processor.cpp
    hoshidicts_src/text_processor/kanji_standardization_data.cpp
    hoshidicts_src/scan/word_scan.cpp
    hoshidicts_src/deinflector.cpp
    hoshidicts_src/query.cpp
    hoshidicts_src/lookup.cpp
    hoshidicts_src/popup_json.cpp
)

target_compile_features(hoshidicts PUBLIC
    cxx_std_23
)

target_include_directories(hoshidicts PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_external/utfcpp/source
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_external/xxHash
)

# Platform-conditional linking
set(HOSHIDICTS_PLATFORM_LIBS "")
if(ANDROID)
  list(APPEND HOSHIDICTS_PLATFORM_LIBS log)
endif()

target_link_libraries(hoshidicts PRIVATE
    glaze::glaze
    libzstd_static
    libdeflate_static
    unordered_dense
    utf8proc::utf8proc
    ${HOSHIDICTS_PLATFORM_LIBS}
)

if(HOSHIDICTS_IOS)
  # iOS: STATIC so the FFI + hoshidicts symbols end up in the Runner image, which
  # is where DynamicLibrary.process() resolves them from.
  add_library(hoshidicts_ffi STATIC
      hoshidicts_ffi.cpp
  )
else()
  add_library(hoshidicts_ffi SHARED
      hoshidicts_ffi.cpp
  )
endif()

target_compile_features(hoshidicts_ffi PRIVATE
    cxx_std_23
)

target_include_directories(hoshidicts_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
)

target_link_libraries(hoshidicts_ffi PRIVATE
    hoshidicts
    ${HOSHIDICTS_PLATFORM_LIBS}
)

if(APPLE AND NOT HOSHIDICTS_IOS)
  set_target_properties(hoshidicts_ffi PROPERTIES
      INSTALL_NAME_DIR "@rpath"
      BUILD_WITH_INSTALL_NAME_DIR TRUE
  )
endif()

# iOS: merge the FFI static archive and every static dependency it links into a
# single self-contained archive (libhoshidicts_ffi_merged.a) so the Xcode build
# phase can force_load exactly one file into Runner. libtool -static resolves the
# recursive INTERFACE link deps for us via generator expressions.
if(HOSHIDICTS_IOS)
  set(HOSHIDICTS_MERGED_ARCHIVE
      ${CMAKE_BINARY_DIR}/libhoshidicts_ffi_merged.a)
  # Merge the FFI archive + its static deps into one archive that the iOS Runner
  # force_loads. Delegated to a helper script because the merge must run inside
  # Xcode's per-target env (EFFECTIVE_PLATFORM_NAME / CONFIGURATION) and reference
  # dependency archives in other CMake subprojects, which the Xcode generator
  # cannot express via $<TARGET_FILE> for cross-project targets.
  add_custom_command(
      TARGET hoshidicts_ffi POST_BUILD
      COMMAND bash
          ${CMAKE_CURRENT_SOURCE_DIR}/merge_ios_archives.sh
          ${CMAKE_BINARY_DIR}
          ${HOSHIDICTS_MERGED_ARCHIVE}
      COMMENT "Merging hoshidicts static archives into libhoshidicts_ffi_merged.a"
      VERBATIM)
endif()

# Windows: set output name without 'lib' prefix
if(WIN32)
  set_target_properties(hoshidicts_ffi PROPERTIES
      PREFIX ""
      OUTPUT_NAME "hoshidicts_ffi"
  )
endif()

# JNI bridge for Android Kotlin popup (only built on Android)
if(ANDROID)
  add_library(hoshidicts_jni SHARED
      hoshidicts_jni.cpp
  )

  target_compile_features(hoshidicts_jni PRIVATE
      cxx_std_23
  )

  target_include_directories(hoshidicts_jni PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
  )

  target_link_libraries(hoshidicts_jni PRIVATE
      hoshidicts
      log
  )
endif()
