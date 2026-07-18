# hibiki_torrent — 内置 libtorrent 引擎 C ABI bridge（阶段1a walking skeleton）

番剧下载「内置 libtorrent 引擎」epic 的阶段1a：**有界** walking skeleton，只
证明 `libtorrent 2.x 构建 → 自写 C ABI → ffigen/Dart FFI` 在 Windows 端到端
打通，**不实现**磁力/元数据/下载管线（那是阶段1b）。

选型（已定）：libtorrent 2.x（BSD-3）+ 自写 C ABI（不被 GPL/非 BSD 依赖传染）
+ Dart FFI + ffigen，照本仓库 `native/hoshidicts` 那套 C++ FFI 范式。

## 结构

```
native/hibiki_torrent/
  CMakeLists.txt                       # find_package(LibtorrentRasterbar) + SHARED lib
  hibiki_torrent_ffi.cpp               # C ABI 实现
  hibiki_torrent_include/
    hibiki_torrent.h                   # C ABI 头（ffigen 入口）
packages/hibiki_torrent/               # Dart 侧
  ffigen.yaml                          # 从上面头文件生成绑定
  lib/src/ffi/hibiki_torrent_bindings.dart   # 绑定
  lib/src/embedded_torrent_engine.dart        # DynamicLibrary 薄封装
  tool/version_harness.dart            # 端到端证明 harness
  test/ffi_smoke_test.dart             # 冒烟测试（无库则 skip）
```

## C ABI（阶段1a 只这三个）

- `const char* ht_libtorrent_version(void)` — libtorrent 版本串（静态存储，勿 free）
- `void* ht_session_create(void)` — 建不监听端口的 session，空壳句柄
- `void ht_session_destroy(void*)` — 销毁句柄

## Windows 构建（standalone，不经 flutter windows runner）

libtorrent 经 **vcpkg** 提供（本机验证过的获取路径）：

```bash
# 1) 装 libtorrent（一次性，约 20~40min，拉 boost + openssl 从源码编）
export HTTPS_PROXY=http://127.0.0.1:34151 HTTP_PROXY=http://127.0.0.1:34151
git clone https://github.com/microsoft/vcpkg <vcpkg>
<vcpkg>/bootstrap-vcpkg.bat -disableMetrics
<vcpkg>/vcpkg install libtorrent:x64-windows

# 2) 配置 + 构建 bridge DLL
cd native/hibiki_torrent
cmake -B build -S . -A x64 \
  -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build --config Release
# 产物：build/Release/hibiki_torrent_ffi.dll（+ vcpkg applocal 部署的
# torrent-rasterbar/boost/openssl 依赖 DLL）
```

## 端到端证明

```bash
cd packages/hibiki_torrent && dart pub get
dart run tool/version_harness.dart \
  ../../native/hibiki_torrent/build/Release/hibiki_torrent_ffi.dll
# 期望输出：libtorrent version: 2.0.x.0 / PASS
```

冒烟测试走 `HIBIKI_TORRENT_LIB` 环境变量指向 DLL；库不存在时整组 skip，
CI/未构建环境不因缺 DLL 而红。

## ffigen 重生成绑定

`lib/src/ffi/hibiki_torrent_bindings.dart` 由 `ffigen.yaml` 对 `hibiki_torrent.h`
生成。本机需装 LLVM/libclang：

```bash
cd packages/hibiki_torrent
dart run ffigen --config ffigen.yaml
```

无 libclang 的机器上，已入库的手写绑定与 ffigen 对该 3 函数的输出等价。

## 尚未做（阶段1b 及以后）

- 未接进 `hibiki/windows/CMakeLists.txt` 的 flutter runner —— 接入前 `flutter
  build windows` 不依赖 vcpkg/libtorrent，避免破坏未装 libtorrent 的构建环境。
  1b 落地 `EmbeddedTorrentBackend` 时再决定「vcpkg 预装 vs FetchContent vs
  vendored 预编译」的 app 集成方案。
- 磁力/元数据/文件列表/顺序下载/边下边播 —— 阶段1b，实现
  `hibiki/lib/src/media/torrent/torrent_backend.dart` 的 `TorrentBackend` 接口。
```
