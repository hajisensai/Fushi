cmake_minimum_required(VERSION 3.22.1)
cmake_policy(SET CMP0077 NEW)

project(hoshidicts_ffi LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "")
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "")
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "")
set(ZSTD_BUILD_STATIC ON CACHE BOOL "")

set(LIBDEFLATE_BUILD_SHARED_LIB OFF CACHE BOOL "")
set(LIBDEFLATE_BUILD_GZIP OFF CACHE BOOL "")

add_subdirectory(hoshidicts_external/glaze)
add_subdirectory(hoshidicts_external/zstd)
add_subdirectory(hoshidicts_external/unordered_dense)
add_subdirectory(hoshidicts_external/libdeflate)

add_library(hoshidicts STATIC
    hoshidicts_src/hash/hash.cpp
    hoshidicts_src/hash/bloom.cpp
    hoshidicts_src/importer.cpp
    hoshidicts_src/memory/memory.cpp
    hoshidicts_src/zip/zip.cpp
    hoshidicts_src/json/yomitan_parser.cpp
    hoshidicts_src/mdx/mdx_reader.cpp
    hoshidicts_src/text_processor/text_processor.cpp
    hoshidicts_src/deinflector.cpp
    hoshidicts_src/query.cpp
    hoshidicts_src/lookup.cpp
)

target_include_directories(hoshidicts PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_external/utfcpp/source
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_external/xxHash
)

target_link_libraries(hoshidicts PRIVATE
    glaze::glaze
    libzstd_static
    libdeflate_static
    unordered_dense
    log
)

add_library(hoshidicts_ffi SHARED
    hoshidicts_ffi.cpp
)

target_include_directories(hoshidicts_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/hoshidicts_include
)

target_link_libraries(hoshidicts_ffi PRIVATE
    hoshidicts
    log
)
