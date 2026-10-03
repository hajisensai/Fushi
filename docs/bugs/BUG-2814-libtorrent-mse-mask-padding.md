## BUG-2814 · libtorrent 2.0.11 MSE 握手掩码未补齐，约 1/256 次加密连接被对端以 invalid info-hash 拒绝
- **报告**：2026-09-30（用户：「查一下 Windows 那个 ip_filter 偶发失败」；排查 `embedded_pipeline_test.dart` 的 ip_filter 用例时在本地复现里发现）
- **真实性**：✅ 真 bug（libtorrent 上游缺陷，已在 RC_2_0 / v2.1.0 修复，2.0.11 没有）。根因在 libtorrent v2.0.11
  `src/pe_crypto.cpp:115-126` 的 `dh_key_exchange::compute_secret()`：req3 异或掩码用裸
  `mp::export_bits()` 写进一个**未初始化**的 `std::array<char, 96>` 再整段哈希。共享密钥首字节为 0 时写不满
  96 字节，尾部是栈上残留，两端算出不同的掩码。同步哈希 req1 与 RC4 密钥走的是补齐到 96 字节的
  `export_key()`（`pe_crypto.cpp:65-87`），所以接收方能找到同步点，紧接着 `find_encrypted_torrent`
  （`session_impl.cpp:4668`）反查失败，以 `invalid info-hash` 断开（`bt_peer_connection.cpp:3005`）。
- **[x] ① 已修复** —— overlay port 回移上游 `arvidn/libtorrent@e7049d21d335`「fix dh shared secret padding」原样一行：
  `native/fushi_torrent/vcpkg-ports/libtorrent/dh-shared-secret-padding.patch`，挂进 `portfile.cmake` 的
  `PATCHES`，port-version 1 → 2。四条产线（Windows DLL / Android `.so` ×2 脚本 / Linux 静态 `.so`）都经
  `-DVCPKG_OVERLAY_PORTS` 吃到；原生产物缓存键是 `native/fushi_torrent` 整树哈希，会自动重编。
- **[x] ② 已加自动化测试** —— `fushi/test/build/libtorrent_version_pin_guard_test.dart`
  「libtorrent overlay 的补丁都挂在 PATCHES 上，且关键 hunk 没被改丢」：钉住补丁在 libtorrent 那个
  `vcpkg_from_github` 的 `PATCHES` 里、删掉的是未初始化数组、加上的是 `export_key`。去掉 `PATCHES` 那一行
  守卫即红（变异验证过）。行为层做不到确定性：触发条件是随机 DH 密钥首字节为 0，库也不导出
  `dh_key_exchange`。
- **备注**：
  - **本地实证**（`D:\codehibiki\native\fushi_torrent\build\vcpkg_installed` 的 2.0.11 + MSVC 直编探针，
    逐步复刻 ip_filter 用例、两端开全量 peer 日志）：约 1000 次加密握手里 4 次接收方
    `sync point (hash) found at offset N`（N 恰为发起方 PadA 长度，不是误同步）后立刻
    `CONNECTION_FAILED ... invalid info-hash`；这 4 次的共享密钥（日志 `looking for synchash ... secret:`）
    **全部**以 `00` 开头（`000e91f1…` / `00ae1f4f…` / `00bd57bc…` 等），反过来每个 `00` 开头的握手都失败了，
    4/4 双向对应。
  - **影响**：发起方在加密尝试开始时就 `fast_reconnect(true)` 并把 `pe_support` 置假，被拒后立刻明文重连，
    所以默认 `pe_enabled` 下通常只是白白多一轮连接（本用例里 metadata 从约 2 s 拖到 2.3–3.6 s）。用户把加密
    策略设成「强制」（`ht_apply_session_settings` enc_policy=1）时没有明文退路，只能靠有限次 fast_reconnect
    重掷 DH。**它不是 ip_filter 用例 CI 偶发红的原因**：那次红是 listen socket 整条丢失，见 BUG-2023。
  - 清理条件：bridge 迁到 libtorrent 2.1 时直接删补丁（v2.1.0 已含修复），见 `vcpkg-ports/README.md`。
