## BUG-3981 · srs-remote-review-scope-leak-and-browse-ops
- **报告**：2026-11-02（PR #2767 远程复习审查）
- **真实性**：✅ 真 bug，四处：
  1. 远程牌组列表 / 复习页 / 浏览等压出的页面脱离 `SrsRemoteCollectionScope`，读写本机根作用域的库：`fushi/lib/src/pages/implementations/srs/srs_remote_review_page.dart` `_SrsRemoteDeckListPageState._push` 裸 `Navigator.of(context).push(adaptivePageRoute(...))`（路由建在导航器 overlay 里，不在作用域子树下）；`srs_review_page.dart` 的笔记编辑 / 浏览 / 模板编辑 / 牌组设置四处 push 同理。
  2. 远程 `browseCommand` 把任意 sync2 内核命令透传给已配对设备（`seal_file` / `open_file` 按请求给的路径读写主机文件，`apply` / `migrate` 绕开写锁）：`packages/fushi_engine/lib/srs/srs_remote_store.dart` 的 `'browseCommand'` op + `srs_db_store.dart` `browseCommand` 直接 `_sync2Raw(request)`，无 op 白名单。
  3. 远程作答的基准核对（`cardRow` 比 `lastLogId`）在写锁外、记日志在锁内：两次 await 之间主机本机作答落库 → 同一张卡记两条日志（`srs_remote_store.dart` `'answerAndStudy'` op）。
  4. 服务端写操作只在客户端带 profile 时才核对，不带 profile 也执行（`SrsRemoteStoreService.call` / `_run`）。
- **[x] ① 已修复** — 新增 `fushi/lib/src/srs/srs_navigation.dart`：`srsPushPage` / `srsPageRoute`（建路由时取调用方的 `ProviderContainer`，用 `UncontrolledProviderScope` 带进新路由），`srsInheritProviderScope` 也搬到这里（`srs_app_host.dart` 转出）；复习模块全部压页（`pages/implementations/srs/*.dart` 与 `srs_change_note_type.dart`）改走 `srsPushPage`。`SrsDbStore.browseCommand` 只接受 `kSrsBrowseOps`（与 `ffi.rs` 分派到 browse 会话的那组相同），远程 op 先校验、不在内回 400 `bad_request`。作答的核对基准 + `answerAndStudy` 整段包进 `s.runExclusive`（可重入）。写操作缺 profile 回 400。顺带修了合并 PR #2765 后 `SrsRemoteStore.syncConflicts` 缺 `entity` 参数的编译错误（远程 op 透传 `entityKind` / `entityId`）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_remote_review_test.dart`「远程牌组列表压出的复习 / 浏览 / 牌组设置 / 添加笔记都读写主机的库，不碰本机库」（变异实测：去掉作用域继承即红）；`fushi/test/srs/srs_remote_store_parity_guard_test.dart`「复习模块里压页面一律经 srsPushPage」守卫；`packages/fushi_engine/test/srs/srs_remote_store_test.dart`「browseCommand 只放行浏览会话命令」「写操作不带 profile 一律 400」「作答的基准核对与记日志在同一个写独占区」（变异实测：去掉独占区即 200 而非 409）。
- **备注**：弹窗（`showAppDialog` 等）内容目前都不读复习库 provider，未纳入守卫；`srs_review_layout_sheet` 读的是设备本地偏好。
