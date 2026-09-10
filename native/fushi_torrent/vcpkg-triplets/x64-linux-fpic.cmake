# Overlay triplet：Linux x64 **静态**依赖 + 全部 -fPIC。
#
# 用途：无头服务端随包的 libfushi_torrent_ffi.so（build_linux_so.sh）。与 Android
# 同一决策——libtorrent / boost / openssl 全部静态链进这一个 .so，目标机不装任何
# libtorrent-rasterbar 运行库（此前动态链发行版包，等于逼用户装 apt 包或退到外接
# qBittorrent）。
#
# 与 vcpkg 自带 x64-linux 的唯一区别是显式 -fPIC：静态归档要被链进共享库，所有
# 目标文件必须位置无关。cmake 系 port 多数自己设了 CMAKE_POSITION_INDEPENDENT_CODE，
# 但 boost（b2）/ openssl（Configure）不一定，漏一个就是 relocation R_X86_64_32
# 链接失败。VCPKG_C(XX)_FLAGS 对所有构建系统生效，一处兜底。
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_C_FLAGS "-fPIC")
set(VCPKG_CXX_FLAGS "-fPIC")
