## BUG-1185 · 远端制卡查重吞掉认证失败，静默答「不重复」

- **报告**：2026-07-28（用户：巡检发现，互联「制卡到已配对设备」查重路径）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/sync/hibiki_remote_mining_client.dart:79-85`（修复前）——
  `HibikiRemoteMiningClient.isDuplicate` 用裸 `catch (_) { return false; }` 把 `_post` 抛出的
  `SyncAuthError`（主机 401 拒绝互联 token，同文件 `:120` 抛出）连同可重试失败一起吞掉，
  统一压成 `false`。
  - 数据流：popup.js `duplicateCheck` → `dictionary_popup_webview._guardJsBridge<bool>` →
    `dictionary_page_mixin.checkDuplicate` / `base_source_page.onDuplicateCheck` →
    `ankiRepositoryProvider`（开关开时是 `RemoteMiningAnkiRepository`）→
    `RemoteMiningAnkiRepository.isDuplicate` → `RemoteMineSender.isDuplicate`。
  - 后果：token 被对端拒绝时**查重根本没执行**，用户却看到 ➕（可制卡），以为这张卡没做过。
    「答错」比「报错」更糟——同一条链路上 `mineForward` 早就把 401 当成 `SyncAuthError` 上抛
    并渲染成明确失败（`remote_mining_anki_repository.dart:74`），只有查重这一处在说谎。
  - 判据（与 PR#488 同族）：`catch` 该报还是该吞，看这个失败会不会让用户基于错误信息做决定。
    查重答案会直接决定用户「要不要再制一张卡」→ 该报。可重试失败（超时/连接被拒/非 2xx）
    继续 fail-soft 降级是有意设计，不在本 bug 范围内。

- **[x] ① 已修复** — commit `6cb31d5bd`
  - `hibiki/lib/src/sync/hibiki_remote_mining_client.dart`：新增三态 `RemoteDuplicateCheck`
    （`duplicate` / `notDuplicate` / `authRejected`），`RemoteMineSender.isDuplicate` 返回值
    由 `bool` 升为三态。`SyncAuthError` 单独走 `on SyncAuthError → authRejected`，其余异常
    仍降级 `notDuplicate`（fail-soft 语义零变化）。
  - `hibiki/lib/src/anki/remote_mining_anki_repository.dart`：`isDuplicate` 收到 `authRejected`
    时经注入的 `RemoteMiningAuthReporter` **上报给用户**（同实例只报一次，避免每次查词刷屏），
    并复用与 `mineEntry` 同一句 `tokenRejectedMessage`。
  - `hibiki/lib/src/anki/anki_view_model.dart`：`ankiRepositoryProvider` 把 reporter 接到
    `HibikiToast.showMine(status: failed)`。
  - **保留 bool 的理由**（不是妥协的借口，是范围判断）：`BaseAnkiRepository.isDuplicate` 的
    `Future<bool>` 契约一路铺到 popup.js 的 ✓/➕ **两态**按钮（还有 3 份 popup 镜像 + 静态守卫
    测试），把第三态推到 UI 属于另一个量级的改动。本修复把「静默答错」降级为「答 false 但
    明确告诉用户配对已失效、查重不可信」；返回 `false` 而非 `true` 是刻意的——用户真按 ➕ 时
    `mineEntry` 会用同一句话明确失败，不会悄悄多出重复卡；谎报 `true` 反而会让用户以为卡已
    做好并就此走开。若谎报 `true` 或直接抛异常，异常会被 `_guardJsBridge<bool>` 再吞回 `false`
    且用户依然看不到——所以抛异常在这里解决不了问题。

- **[x] ② 已加自动化测试** — commit `6cb31d5bd`
  - `hibiki/test/sync/hibiki_remote_mining_client_duplicate_test.dart`（新增，最强可落地层：
    用 `MockClient` 真实驱动 HTTP 状态码 + 内存 Drift `SyncRepository`）：401 → `authRejected`；
    200 `duplicate:true/false` → `duplicate`/`notDuplicate`；503 / 传输层异常 / 无候选 →
    `notDuplicate`（fail-soft 不回归）。
  - `hibiki/test/anki/remote_mining_anki_repository_test.dart`：`authRejected` → 上报用户且
    只报一次、返回 `false`；`notDuplicate` → 不误报鉴权失败。
  - **负向验证**：把 `on SyncAuthError → authRejected` 摘掉（回到裸 `catch` 吞掉）后
    `FLUTTER TEST VERDICT: FAILED`，`BUG-1185 主机 401 → authRejected` 转红
    （`Expected: authRejected / Actual: notDuplicate`）；还原后 15 tests 全绿。

- **备注**：`tokenRejectedMessage` 沿用同文件既有的硬编码英文（`mineEntry` 401 分支原本就是
  硬编码英文，本次把两处合并成同一个常量）。若要 i18n 化应连同 `mineEntry` 那句一起做，属
  独立跟进项，不在本 bug 范围内。
