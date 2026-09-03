cmake_minimum_required(VERSION 3.16)
cmake_policy(SET CMP0077 NEW)

project(fushi_torrent_ffi LANGUAGES CXX)

# libtorrent 2.x 要求 C++17（或更高）。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Linux/桌面共享库里链接静态依赖时用 PIC（与 fushidicts 一致的姿态）。
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

add_library(fushi_torrent_ffi SHARED
    fushi_torrent_ffi.cpp
)

target_include_directories(fushi_torrent_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/fushi_torrent_include
)

target_link_libraries(fushi_torrent_ffi PRIVATE
    LibtorrentRasterbar::torrent-rasterbar
)

# Windows：去掉 'lib' 前缀，DLL 名固定为 fushi_torrent_ffi.dll（Dart 侧按此
# DynamicLibrary.open）。
if(WIN32)
  set_target_properties(fushi_torrent_ffi PROPERTIES
      PREFIX ""
      OUTPUT_NAME "fushi_torrent_ffi"
  )
endif()

if(APPLE)
  set_target_properties(fushi_torrent_ffi PROPERTIES
      INSTALL_NAME_DIR "@rpath"
      BUILD_WITH_INSTALL_NAME_DIR TRUE
  )
endif()

# Android：产物名走默认 lib 前缀（libfushi_torrent_ffi.so，Dart 侧
# defaultLibraryNames 按此名 DynamicLibrary.open）。依赖（libtorrent/boost/
# openssl）由 vcpkg android triplet 提供**静态归档**，全部链进这一个 .so ——
# jniLibs 里只随包一个文件，没有 Windows 那套同目录依赖预载问题。
if(ANDROID)
  # Android 15+ 的 16KB page size 设备要求 ELF segment 按 16KB 对齐；NDK r28
  # 起是默认，r27 及以下需显式给。恒设无害（4KB 设备兼容 16KB 对齐产物）。
  target_link_options(fushi_torrent_ffi PRIVATE "-Wl,-z,max-page-size=16384")
endif()
