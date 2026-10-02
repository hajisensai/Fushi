# Overlay triplet：macOS arm64 **静态**依赖，部署目标钉 13.4。
#
# 用途：macOS 桌面版随包的 libfushi_torrent_ffi.dylib（build_macos_dylib.sh）。与
# Android / Linux 同一决策——libtorrent / boost / openssl 全部静态链进这一个 dylib，
# Contents/Frameworks 里只随包一个文件，用户机不装任何 Homebrew 运行库。
#
# 与 vcpkg 自带 arm64-osx 的唯一区别是 VCPKG_OSX_DEPLOYMENT_TARGET：自带 triplet 不设，
# 依赖就按构建机 SDK 的系统版本编，链进 bridge 后在比构建机老的 macOS 上加载失败；
# 必须与 fushi/macos/Runner.xcodeproj 的 MACOSX_DEPLOYMENT_TARGET（13.4）对齐。
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 13.4)
