## BUG-1772 · vcpkg 未钉版，libtorrent 2.0→2.1 漂移打断 Windows DLL 与 Android .so 构建
- **报告**：2026-08-22（CI 巡检发现，非用户报告）
- **真实性**：✅ 真 bug。根因 `.github/workflows/build-multiplatform.yml`（原第 553 行）
  与 `release-desktop.yml`（原第 328 行）的 classic `vcpkg install libtorrent:x64-windows`、
  以及 `native/fushi_torrent/build_android_so.sh`（原第 35 行）的
  `vcpkg install libtorrent:$triplet` —— 三处都**没有任何版本钉定**，装到哪个版本
  完全由 runner 镜像内固化的 vcpkg 修订决定，构建不可重现。
  vcpkg 在 `e90cc0982b`（2026-08-12）把 `ports/libtorrent` 从 2.0.11 升到 2.1.1，
  GitHub runner 镜像 `20260818.277.1` 跟进后，`native/fushi_torrent/fushi_torrent_ffi.cpp`
  的五处 2.0-only API 同时编不过（namespace 也变成 `libtorrent::v2_1`）：
  - `fushi_torrent_ffi.cpp:375` / `:580` / `:1048` —— `torrent_info::files()` 已移除
  - `fushi_torrent_ffi.cpp:925` —— `lt::add_files` 已移除
  - `fushi_torrent_ffi.cpp:927` —— `create_torrent(file_storage)` 构造器已移除
  - `fushi_torrent_ffi.cpp:944` —— `lt::from_span` 已移除
  - `fushi_torrent_ffi.cpp:1207` / `:1208` —— `peer_info::ip` 已改名

  影响面比「CI 红」更重：`native/fushi_torrent/build_windows_dll.ps1` 对 Release
  校验 4 个 DLL（bridge + torrent-rasterbar + ssl + crypto）缺一即 throw，
  所以 **Windows 正式发布包直接出不来**；Android `.so` 同源同错，`Build Release APK`
  的 build job 一并红。develop 上从 `5d1f6d3b`（2026-08-21 14:56）起连红，
  **不是任何一个 commit 引入的** —— `native/fushi_torrent/` 在最后一次绿
  （`998331c4`，2026-08-20 22:03）到首红之间零改动，`fushi_torrent_ffi.cpp`
  最后一次修改是 2026-08-11。纯粹的外部依赖漂移。

- **[x] ① 已修复** — `f1de92b`（本条目所在提交）。`native/fushi_torrent/vcpkg.json`
  改用 vcpkg manifest 模式 + `overrides` 把 libtorrent 钉死在 **2.0.11**
  （2.0 线终点），`builtin-baseline` 取 `aae277acf4e7de287ddb5e208b5316614de6aad7`
  —— 2.1.1 落地前最后一批 master，它给出的 libtorrent 2.0.11 + boost 1.91.0 +
  openssl 3.6.3 正是上游一起验过的组合。三处 classic `vcpkg install` 全部删除，
  依赖改由 cmake configure 时的 vcpkg 工具链按 manifest 装。

  两个配套修正（都是 manifest 模式带来的、不改就是新的静默破坏）：
  1. **Android overlay triplet 必须传给 cmake**（`build_android_so.sh` /
     `.ps1` 新增 `-DVCPKG_OVERLAY_TRIPLETS=`）。manifest 模式下装依赖的是工具链
     而不是命令行，overlay 只传给已删除的 `vcpkg install` 等于不参与，会静默退回
     vcpkg 自带的 `arm64-android`（钉 API 28）—— 即 `vcpkg-triplets/arm64-android.cmake`
     注释里那个 boost.asio `aligned_alloc` undefined symbol。
  2. **baseline 可用性前置检查**（新增 `native/fushi_torrent/vcpkg_baseline.ps1`
     的 `Assert-VcpkgBaseline`，`build_android_so.sh` 内联同款 bash 版）。
     实测确证：baseline 不在本地时 vcpkg **硬失败且不会自动 fetch**，报的是
     `path 'versions/baseline.json' exists on disk, but not in <sha>`；而版本条目
     又来自工作区 `versions/`（跟着 HEAD 走）。充分条件是「baseline 是本地 HEAD
     的祖先」（`versions/` 只增不删），检查不过时直接提示 `git -C <vcpkg> pull`。

  三条 workflow 的 vcpkg 二进制缓存 key 一并 bump（Windows `v2`→`v3`、
  Android `v1`→`v2`）：钉版换掉了 libtorrent/boost/openssl 的 ABI hash，旧条目
  一个都用不上，而 `actions/cache` 命中即不回存，不 bump 会每次冷编 40min
  （TODO-2668 记的同一处病灶）。

  **本地实证**（本机 `D:\APP\vcpkg`）：`vcpkg install --dry-run --triplet
  x64-windows --x-manifest-root=native/fushi_torrent` 解析出
  `libtorrent[core,iconv]:x64-windows@2.0.11` + `openssl:x64-windows@3.6.3`，
  退出码 0 —— manifest 写法、`overrides` 字段名（2.0.11 的 port 用 relaxed
  scheme，必须写 `version` 而非 `version-string`）、feature 解析全部正确。
  「baseline 不在本地即硬失败」也在本机复现过（本机 vcpkg HEAD 停在 2026-07-17）。

- **[x] ② 已加自动化测试** — `fushi/test/build/libtorrent_version_pin_guard_test.dart`（4 条）。
  源码扫描守卫，钉住让钉版继续生效的三个条件 + 一条同进退约束：
  ① `vcpkg.json` 必须有 `builtin-baseline` 且 `overrides` 把 libtorrent 钉在 2.0.x；
  ② 三条 workflow 的非注释行不得再出现 `install libtorrent`（退回 classic 就是重演）；
  ③ 两个 Android 脚本必须给 cmake 传 `VCPKG_OVERLAY_TRIPLETS`；
  ④ 只要 `fushi_torrent_ffi.cpp` 还含 2.0-only 调用，钉定就不许动 —— 防止
  「删了 overrides 却没迁代码」或反之的各说各话。
  **变异实测**：四条断言逐一破坏（改 overrides 的 name、workflow 加回 classic
  install、Android 脚本改掉 overlay 变量名、cpp 里的 2.0 标记全改名），
  **全部变红**；还原后四个文件 sha256 逐一比对一致。

- **备注**：`overrides` 是**买时间**，不是终局。2.0.11 是 2.0 线终点（2025-01-30
  落地），上游不再更新，安全修复也不会有 —— 这一点在刚做完 ffmpeg 漏洞升级的
  仓库里尤其值得盯。真正的出口是把 bridge 迁到 2.1 API（那五处调用 + `v2_1`
  namespace），迁完即可删掉 `vcpkg.json` 的 `overrides` 与守卫的第 ④ 条。
  另：同一批 CI 里 android job 的 `appSmoke` 失败是**环境 flaky**（flutter driver
  握手阶段 `getIsolate: Service has disappeared`，测试体一行断言都没跑到，重跑即绿），
  与本条目无关，未单列。
