## BUG-2023 · PR#1129 windows job FFI 测试 13 条红：全部 listen_port=0（未复现）

- **报告**：2026-09-02（用户：PR #1129 `worktree-p2p-proxy-mixed-mode` head `2071813d26` 在 `build-multiplatform.yml` 的 `windows` job → `Run fushi_torrent FFI tests against the freshly built DLL` 步骤 `22 tests passed, 13 failed`，判为本 PR 引入的真回归）
- **真实性**：❌ **未复现 —— 不是本 PR 引入的回归**，是 GitHub Windows runner 上「回环临时端口 bind 不上」的环境性偶发（同一 commit 重跑即绿）。
- **[ ] ① 未修复** —— 无代码可修（下有排除依据）。
- **[ ] ② 未加自动化测试** —— 同上。
- **复现次数**：2 次（2026-09-02 早 PR#1129；2026-09-02 PR#1147）。二次出现把它从
  「偶发、可忽略」升级成「**会持续拦住不相干的 PR**」——见「第二次出现」。
- **备注**：见下。

### 现场

13 条失败全在 `packages/fushi_torrent`，形状唯一：任何**带监听接口**的 session
`listen_port` 恒为 0。

- `test/detail_info_test.dart:85`（`sessionStatus`）直接 `Expected: a value greater
  than <0> / Actual: <0>`，不是超时。
- 其余 12 条卡在 `LocalSeedRig.start`（`packages/fushi_torrent/lib/src/testing/local_seed_rig.dart:76` →
  `:126`）的 `Bad state: timeout waiting for seeder listen port`，各耗满 10s。
- 同一进程里**不监听**的 session（`EmbeddedTorrentSession.open(engine)`，
  `listen_interfaces=""`）相关的 22 条全绿——包括本 PR 新增的
  `ffi_smoke_test.dart` 混合档 `applyProxy` 用例。

`LocalSeedRig` 的就绪判据本身没问题：它显式传 `listenInterfaces: '127.0.0.1:0'`
（`local_seed_rig.dart:73`），跟本 PR 把生产侧默认改成双栈
（`fushi/lib/src/media/torrent/embedded_torrent_host.dart:216`
`'0.0.0.0:6881,[::]:6881'`）完全无关；`_waitFor` 也只等「第一个可用端口」，
不存在「多接口下判据不成立」。

libtorrent 2.0.11 里 `session_impl::listen_port()`（`src/session_impl.cpp:5517`）
返回 0 只有两种可能：`m_listen_sockets` 为空（`setup_listener` 里 TCP/UDP bind 失败，
`src/session_impl.cpp:1606`），或 front socket 没有 `accept_incoming`（只有
`proxy_type != none && proxy_peer_connections` 的 proxy 伪 socket 分支会这样，
`src/session_impl.cpp:2060`）。这些测试全程没配代理，所以只剩「bind 失败」。

### 排除依据（为什么不是本 PR）

1. **同 commit 重跑即绿，且构建输入逐位一致。** `rerun-failed-jobs` 后
   run 33533866815 的 windows job（job 99958160996）又从源码编了一遍
   `libtorrent[core,iconv]:x64-windows@2.0.11#1`，**package ABI 与红那次完全相同**
   （`415a36beb415b68342bde0bc9017d13dd0163723a79e646ab90623d6a8a602a8`
   —— vcpkg 的 ABI hash 覆盖 portfile/补丁/三依赖/triplet/编译器，相等即构建输入
   逐位相同），结果 `🎉 35 tests passed.`，整个 windows job success。runner 镜像
   `20260824.284.2`、MSVC 19.44.35228.0、Windows SDK 10.0.26100.0、boost 1.91.0、
   openssl 3.6.3 两次也全部相同。**同一份二进制，一次全红一次全绿 = 环境。**
2. **同分支上一个 commit 也是从源码编的，且绿。** `5a493ec265`（run 33487944558 /
   job 99792339313）已经带 `vcpkg-ports/` overlay、`libtorrent@2.0.11#1`、
   三个构建脚本的 `VCPKG_OVERLAY_PORTS`，`Elapsed time to handle
   libtorrent:x64-windows: 10 min`（ABI `6cf9f41b…`，从源码编），
   `🎉 35 tests passed.`。红的那次是 ABI `415a36be…` / 9.8 min。红绿两次构建之间**唯一**的输入差异是补丁文件多了
   `read()` 那个 hunk（commit `32f2bd1853`）。
3. **那个 hunk 在直连档是逐位等价的 no-op。** 改的是
   `src/udp_socket.cpp` 的 `udp_socket::read()`：把
   `if (active_socks5()) { if (p.from != target) continue; ... }` 改写成
   `if (active_socks5() && p.from == target) { ... } else { 原 proxy_only 分支 }`。
   `active_socks5()` = `m_socks5_connection && m_socks5_connection->active()`，
   而 `m_socks5_connection` 只在 `udp_socket::set_proxy_settings` 收到
   `socks5 / socks5_pw` 时才被建出来；这批测试的 session 从建号到断言全程
   `proxy_type == none`，两条分支都走 else，`type != none` 恒假，一个包都不会
   多丢或少丢。另外两个 hunk（`send` / `send_hostname`）同样被
   `if (use_proxy && m_proxy_settings.type != settings_pack::none)` 挡住。
   **补丁不可能影响 bind。**
4. **本机复现失败（即：复现不出红）。** 在 worktree 里用
   `native/fushi_torrent/build_windows_dll.ps1 -VcpkgRoot D:\APP\vcpkg` 从源码编出
   head 的 DLL（含三个 hunk），按 CI 同样的 `FUSHI_TORRENT_LIB` + `dart test` 连跑
   3 次：34 passed / 1 failed，**监听 session 全部拿到端口**，rig 全绿。唯一那条
   failed 是 `embedded_pipeline_test.dart:336`「ip_filter … seeder peer must
   surface in peer_info」，拿 2026-07-18 编的**未打补丁**旧 DLL 跑同一份测试同样
   失败——本机回环太快、1MiB 在首轮 poll 前就过半，属既有的时序敏感用例，与本 PR
   无关（CI 上一直绿）。
5. **develop 侧不是对照组。** develop 的 windows job 命中
   `Windows-vcpkg-libtorrent-x64-windows-v3-…` 缓存，libtorrent 106 ms 直接还原
   （ABI `db19734b…`），从不从源码编。真正的对照组只有本分支那两次源码编译
   （②③）。

### 第二次出现（2026-09-02，PR#1147）

同一天又中一次，**形状逐字相同**：PR **#1147**
（`worktree-fix-ocr-dml-fallback-utf8`，OCR DirectML 回退 + UTF-8 归一）的 `windows`
job 也是 `22 tests passed, 13 failed`，伴随重复的
`Bad state: timeout waiting for seeder listen port`。

这次的排除证据比第一次更硬：

- **#1147 改的 9 个文件里零 torrent 代码**（OCR / DirectML / 编码归一）。
  第一次还需要靠「同 commit 重跑即绿 + vcpkg ABI hash 相等」排除；这次是
  **一条跟 torrent 没任何关系的 PR 直接中招**，「本 PR 引入」已不可能。
- `gh run rerun --failed` 后通过，与第一次一致。

两次叠起来看，它不是「某条 PR 的偶发噪声」，而是 **runner 机器级的系统性风险**：
任何一条 PR 都可能因为它红一次，而红的内容与该 PR 无关。**看到这个形状先
`gh run rerun --failed`，不要去查本 PR 的 diff。**

### 结论与后续

红是 runner VM 侧的 `bind(127.0.0.1, 0)` 失败（Windows 上 Hyper-V/WinNAT 预留掉
动态端口段是已知的机器级偶发），一个 job 内所有进程一起中招，所以看起来「稳定
必红」，实际换台机器就好。**不改代码**：把 IPv6 双栈关掉是撤功能，给 rig 的判据
加特例是掩盖症状，两者都不是根因修。

### 诊断：为什么每次只能报超时（2026-09-02 复核）

已逐行核实：`drain_alerts`（`native/fushi_torrent/fushi_torrent_ffi.cpp:399`，注释里
自称是「**唯一**的 alert 收割点」）只 `alert_cast` 了 `piece_finished` /
`save_resume_data`(+failed) / `file_renamed`(+failed) / `storage_moved`(+failed) /
`dht_stats` / `session_stats` / `file_prio` / `portmap`(+error) 十几个类型，
**没有 `listen_failed_alert`，也没有 `listen_succeeded_alert`**，其余一律丢弃。
而 `ht_session_create` 的 `alert_mask` 已经包含 `status | error`
（`fushi_torrent_ffi.cpp:645`）——**alert 确实发出来了，就是在 bridge 里被默默扔掉**。
这就是为什么两次红都只能看到「端口永远是 0」、拿不到 bind 的 errno。

**本次做了什么**：在 `LocalSeedRig._waitFor` 上加一个只在超时那一刻跑的
`diagnose` 钩子，等端口这一处传 `_describeLoopbackBindHealth`：超时后 Dart 自己
`ServerSocket.bind(127.0.0.1, 0)` 一次，把结果拼进错误文案。探针也失败 = 机器的临时
端口段不可用（本条的形状），探针成功 = 真得去查 bridge。**下次同款红一眼定性，
不需要重编 native。** 它只改错误文案，不改等待判据，不影响红/绿。

**为什么没顺手把 `listen_failed_alert` 收进 `drain_alerts`**：代码量确实不大
（ctx 加一个字段 + 一个 `alert_cast` 分支 + `ht_session_status` 里多一个 JSON 字段），
但它落在 C++ FFI 桥里，而 `native/fushi_torrent/prebuilt/` 是 **gitignore 的**
（`native/fushi_torrent/.gitignore:7`）——想真实测到它必须先拿 vcpkg 从源码编
libtorrent 2.0.11 + 重建 DLL（实测 ~10 分钟），否则就是往桥里提一段**没跑过的**
C++。本条是一条环境性偶发，不值得为一个诊断字段搭一次 native 构建链；上面的 Dart
探针已经拿到了 90% 的定性能力。

**什么时候再做**：下一次有人因别的原因动 `native/fushi_torrent/fushi_torrent_ffi.cpp`
并已经把本地 libtorrent 构建链搭好了，顺手带上（`listen_failed_alert` 的
`error` + `endpoint` 存进 ctx，`ht_session_status` 透出 `"listen_error"`）；
或者探针未来报出「Dart 能 bind、libtorrent 不能」（那就真是 bridge 问题，必须拿 errno）。
