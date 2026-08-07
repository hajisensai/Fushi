cmake_minimum_required(VERSION 3.22.1)
project(kanji_import_query_test LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Reuse the real hoshidicts static lib (pulls in glaze / zstd / libdeflate /
# unordered_dense exactly as the production build does).
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../.. hoshidicts_build)
add_executable(kanji_import_query_test ${CMAKE_CURRENT_SOURCE_DIR}/../kanji_import_query_test.cpp)
# The test source embeds raw UTF-8 kanji bytes (fixtures + comments); without
# /utf-8 MSVC decodes them as code page 936 (GBK) and mangles the file (C4819).
if(MSVC)
  target_compile_options(kanji_import_query_test PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
endif()
target_link_libraries(kanji_import_query_test PRIVATE hoshidicts)
