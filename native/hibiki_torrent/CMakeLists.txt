cmake_minimum_required(VERSION 3.16)
cmake_policy(SET CMP0077 NEW)

project(hibiki_torrent_ffi LANGUAGES CXX)

# libtorrent 2.x 要求 C++17（或更高）。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Linux/桌面共享库里链接静态依赖时用 PIC（与 hoshidicts 一致的姿态）。
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(MSVC)
  # UTF-8 源码/执行字符集，异常，屏蔽 min/max 宏；_WIN32_WINNT 给 Boost.Asio。
  add_compile_options(/utf-8 /EHsc)
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0601)
endif()

# libtorrent 由 vcpkg 提供（find_package config 模式）。上层构建需传入 vcpkg
# 工具链文件（-DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake）
# 与 triplet（x64-windows）。见本目录 README/harness。
find_package(LibtorrentRasterbar CONFIG REQUIRED)

add_library(hibiki_torrent_ffi SHARED
    hibiki_torrent_ffi.cpp
)

target_include_directories(hibiki_torrent_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/hibiki_torrent_include
)

target_link_libraries(hibiki_torrent_ffi PRIVATE
    LibtorrentRasterbar::torrent-rasterbar
)

# Windows：去掉 'lib' 前缀，DLL 名固定为 hibiki_torrent_ffi.dll（Dart 侧按此
# DynamicLibrary.open）。
if(WIN32)
  set_target_properties(hibiki_torrent_ffi PROPERTIES
      PREFIX ""
      OUTPUT_NAME "hibiki_torrent_ffi"
  )
endif()

if(APPLE)
  set_target_properties(hibiki_torrent_ffi PROPERTIES
      INSTALL_NAME_DIR "@rpath"
      BUILD_WITH_INSTALL_NAME_DIR TRUE
  )
endif()
