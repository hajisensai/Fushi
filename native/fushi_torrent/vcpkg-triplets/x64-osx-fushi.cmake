# Overlay triplet：macOS x86_64 **静态**依赖，部署目标钉 13.4。
# 决策与 arm64-osx-fushi.cmake 相同；两片由 build_macos_dylib.sh lipo 成 universal。
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 13.4)
