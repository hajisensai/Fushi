# hibiki_torrent — 内置 libtorrent 引擎 C ABI bridge（阶段1b）

番剧下载「内置 libtorrent 引擎」epic 的 native 层。阶段1a 证明了
`libtorrent 2.x 构建 → 自写 C ABI → ffigen/Dart FFI` 在 Windows 端到端打通；
阶段1b（当前）实现真实下载管线：**磁力 → 元数据 → 顺序下载 → 进度 → 完成**，
外加边下边播原语（sequential + `set_piece_deadline` + 首尾 piece 提优）与
本地做种/测试支撑（`make_torrent` / `connect_peer`）。

选型（已定）：libtorrent 2.x（BSD-3）+ 自写 C ABI（不被 GPL/非 BSD 依赖传染）
+ Dart FFI + ffigen，照本仓库 `native/hoshidicts` 那套 C++ FFI 范式。

## 结构

```
native/hibiki_torrent/
  CMakeLists.txt                       # find_package(LibtorrentRasterbar) + SHARED lib
  hibiki_torrent_ffi.cpp               # C ABI 实现（无自有状态；JSON 出参）
  hibiki_torrent_include/
    hibiki_torrent.h                   # C ABI 头（ffigen 入口；各函数契约见注释）
packages/hibiki_torrent/               # Dart 侧
  ffigen.yaml                          # 从上面头文件生成绑定
  lib/src/ffi/hibiki_torrent_bindings.dart   # 绑定
  lib/src/embedded_torrent_engine.dart        # EmbeddedTorrentEngine + EmbeddedTorrentSession
  lib/src/testing/local_seed_rig.dart         # 本地做种 rig（确定性测试脚手架）
  tool/version_harness.dart            # 工具链证明 harness（1a）
  tool/download_harness.dart           # 真实网络手动冒烟（真机验收用）
  test/ffi_smoke_test.dart             # 冒烟测试（无库则 skip）
  test/embedded_pipeline_test.dart     # 端到端管线测试（本地 rig，零外网）
hibiki/lib/src/media/torrent/
  embedded_torrent_backend.dart        # EmbeddedTorrentBackend implements TorrentBackend
```

## C ABI 一览

会话：`ht_session_create(listen_interfaces, enable_dht)` /
`ht_session_destroy` / `ht_session_listen_port` / `ht_session_set_rate_limits`。
种子：`ht_add_magnet` / `ht_add_torrent_file` / `ht_make_torrent` /
`ht_connect_peer` / `ht_list_torrents` / `ht_torrent_files` /
`ht_torrent_pieces` / `ht_poll_piece_events` / `ht_set_piece_deadline` /
`ht_apply_first_last_priority` / `ht_remove_torrent`。
出参 JSON 一律 `ht_free_string` 释放；详细契约见 `hibiki_torrent.h` 注释。

### 关键语义（踩过的坑，别再踩）

- **不监听 = 连不出去**：libtorrent 的出站连接绑定在 listen socket 上，
  `listen_interfaces` 传空的 session 无法连接任何 peer（1a 空壳/探测专用）。
  要下载必须给监听接口（本地测试 `127.0.0.1:0`，端口 0 = 系统分配）。
- **add 即启动**：libtorrent 默认 add 旗标带 `paused`，起始瞬间会丢弃
  `connect_peer` 且无 tracker/DHT 时无从再发现 peer；bridge 在 add 时清
  `paused`。手动 connect_peer 的调用方仍应在轮询里重试（幂等）。
- **Windows 依赖 DLL 搜索**：`DynamicLibrary.open` 不把目标 DLL 所在目录
  纳入其依赖搜索路径；`EmbeddedTorrentEngine.open` 会先预载同目录的
  vcpkg applocal 依赖（torrent-rasterbar/ssl/crypto）再开主库。
- **firstLastPiecePrio 无 add 期开关**：元数据未就绪无从提优；
  `ht_apply_first_last_priority` 在元数据就绪后调用（返回 0 = 未就绪，
  轮询重试；`EmbeddedTorrentBackend` 已在 listTorrents 轮询里补应用）。

## Windows 构建（standalone，不经 flutter windows runner）

libtorrent 经 **vcpkg** 提供（本机 `D:\APP\vcpkg`，已装 `libtorrent:x64-windows`）：

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

## 测试

```bash
cd packages/hibiki_torrent && dart pub get
# 端到端管线（本地 rig 做种，零外网、确定性；缺 DLL 整组 skip）：
HIBIKI_TORRENT_LIB=<绝对路径>/hibiki_torrent_ffi.dll dart test
# app 侧 TorrentBackend 契约（在 hibiki/ 下）：
HIBIKI_TORRENT_LIB=... flutter test test/media/torrent/embedded_torrent_backend_test.dart
# 真实网络手动冒烟（真机验收）：
dart run tool/download_harness.dart <dll> "<magnet>" <saveDir>
```

## ffigen 重生成绑定

`lib/src/ffi/hibiki_torrent_bindings.dart` 由 `ffigen.yaml` 对 `hibiki_torrent.h`
生成。本机需装 LLVM/libclang：

```bash
cd packages/hibiki_torrent
dart run ffigen --config ffigen.yaml
```

无 libclang 的机器上，已入库的手写绑定与 ffigen 输出等价。

## 阶段2/3 已接线（app 侧）

- **后端选择**：`QbConnectionConfig` 加 `backend` 字段（`qbittorrent` /
  `embedded`；历史配置无此字段回退 qb）。设置→视频→番剧下载新增后端二选一
  分段控件，选内置时隐藏 qb 连接字段。
- **`EmbeddedTorrentBackend implements TorrentBackend`**：分类=保存子目录、
  magnet/.torrent 文件（http URL 拒绝）、firstLastPiecePrio 在 listTorrents
  轮询期补应用。`closesSession` 区分 standalone（自持会话）与 app 共享会话。
- **`EmbeddedTorrentHost`**（app 侧宿主）：拥有常驻引擎 + 单 session，派发
  短命 `backendView()` 给 `AnimeDownloadService` 每 tick 用（视图 close 不
  连累会话）。桌面且 DLL 可用时 `AppModel.startAnimeDownloadService` 懒建，
  DLL 缺失回退 qb。
- **反吸血（阶段3）**：`ht_torrent_peers` 导出 peer_info、`ht_apply_ip_filter`
  执行封禁；`EmbeddedTorrentHost.sweepAntiLeech` 每 tick 把所有种子 peer 喂
  `AntiLeechEngine`，新增封段全量重建 libtorrent ip_filter。服务 tick 加
  `onTick` 钩子（早于 pending 门控，做种期也封）。ip_filter 生效性有测试
  验证（封回环段 → 元数据死等；清空 → 秒连）。

## 阶段4 — Windows DLL 随包（已接 flutter runner）

**分布决策：vendored 预编译**（在「vcpkg 预装 / FetchContent 现编 / vendored
预编译」三选一里选它）。理由：libtorrent 经 vcpkg 首次源码编译约 40min
（boost+openssl+libtorrent），不能强制每台构建机 / CI 都装 vcpkg 并现编；
flutter windows 构建也不便注入 vcpkg 工具链文件。故：

1. **产出**：`native/hibiki_torrent/build_windows_dll.ps1 -VcpkgRoot <vcpkg>`
   编 bridge 并把 4 个运行时 DLL（`hibiki_torrent_ffi` + `torrent-rasterbar`
   + `libssl-3-x64` + `libcrypto-3-x64`，共 ~11MB）收拢到
   `prebuilt/windows-x64/`（git 忽略，不入库——repo 不放二进制，构建/发布
   流程各自现产或从 release 拉取）。
2. **随包**：`hibiki/windows/CMakeLists.txt` 在 hoshidicts 之后加了
   **copy-if-present** 块——`prebuilt/windows-x64/*.dll` 存在则 `install` 到
   `hibiki.exe` 旁，不存在则跳过。因此 `flutter build windows` **不依赖
   vcpkg/libtorrent**：没跑过产出脚本的机器照常构建，只是 app 运行期
   `EmbeddedTorrentHost.open` 因 DLL 缺失返回 null → 自动回退外接 qb。
3. **加载**：`EmbeddedTorrentEngine._openByPlatformDefault` 用
   `DynamicLibrary.open('hibiki_torrent_ffi.dll')`，DLL 与 exe 同目录即命中；
   运行时依赖（torrent-rasterbar/ssl/crypto）也在同目录，被隐式加载。

发布流程接入：CI/release workflow 在打 Windows 包前跑一次
`build_windows_dll.ps1`（需缓存 vcpkg libtorrent，避免每次 40min），或从
预先发布的 release 资产下载这 4 个 DLL 放进 `prebuilt/windows-x64/`。

## 尚未做（多平台 + 真机）

- **多平台**（Android/macOS/Linux）：同样走 vendored 预编译 + 各 runner
  CMake 的 copy-if-present，但需对应工具链编 libtorrent（Android NDK /
  Xcode / gcc），未在本机验证，另起 job。
- http(s) .torrent URL 下载（内置引擎侧 magnet-only；Nyaa 链路产 magnet）。
- 反吸血的真实吸血 peer 触发（PCB 进度作弊需伪造进度的 peer；本地 rig 的
  做种者诚实，自动化只验 ip_filter 执行力 + peer_info 导出 + sweep 不误封，
  真封禁触发留真机）。
