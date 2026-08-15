# Overlay triplet：与 vcpkg 自带 arm64-android 唯一区别是 API level 钉 24。
# 自带 triplet 钉 VCPKG_CMAKE_SYSTEM_VERSION 28，boost.asio 会引用 API 28 才进
# libc 的 aligned_alloc；bridge 按 app minSdk 24 链接时 undefined symbol，
# 且即便链过了也会在 API 24~27 设备上 dlopen 失败。依赖与 bridge 必须同一 API。
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 24)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=arm64-v8a)
