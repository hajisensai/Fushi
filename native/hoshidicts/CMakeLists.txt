cmake_minimum_required(VERSION 3.22.1)
cmake_policy(SET CMP0077 NEW)

project(hoshidicts_ffi LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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

add_subdirectory(hoshidicts_external/glaze EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/zstd EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/unordered_dense EXCLUDE_FROM_ALL)
add_subdirectory(hoshidicts_external/libdeflate EXCLUDE_FROM_ALL)

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
    hoshidicts_src/scan/word_scan.cpp
    hoshidicts_src/deinflector.cpp
    hoshidicts_src/query.cpp
    hoshidicts_src/lookup.cpp
    hoshidicts_src/popup_json.cpp
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
    ${HOSHIDICTS_PLATFORM_LIBS}
)

add_library(hoshidicts_ffi SHARED
    hoshidicts_ffi.cpp
)

target_include_directories(hoshidicts_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
)

target_link_libraries(hoshidicts_ffi PRIVATE
    hoshidicts
    ${HOSHIDICTS_PLATFORM_LIBS}
)

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

  target_include_directories(hoshidicts_jni PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
  )

  target_link_libraries(hoshidicts_jni PRIVATE
      hoshidicts
      log
  )
endif()
