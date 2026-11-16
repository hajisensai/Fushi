# 查词基准（不进 ctest、不进任何产物；只在量性能时手动配置）。
#
#   cmake -S native/fushidicts/benchmark -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build <build>
#   <build>/lookup_bench <manifest.tsv> <transforms 目录> <语料.txt> [选项]
#
# 用法与输出口径见 lookup_bench.cpp 文件头。
cmake_minimum_required(VERSION 3.22.1)
project(fushidicts_benchmark LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(FUSHI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
add_subdirectory(${FUSHI_ROOT} fushidicts_build)

add_executable(lookup_bench lookup_bench.cpp)
target_link_libraries(lookup_bench PRIVATE fushidicts)
target_include_directories(lookup_bench PRIVATE "${FUSHI_ROOT}/fushidicts_src")
if(MSVC)
  target_compile_options(lookup_bench PRIVATE /utf-8 /Zc:__cplusplus /permissive-)
endif()
