## BUG-1145 · 桌面剪贴板复制历史永远为空（采集回调从未触发）
- **报告**：2026-07-27（用户：桌面查词浮窗/面板的 🕘「复制历史」点开永远是空列表）
- **真实性**：✅ 真 bug，既有缺陷、非任何 PR 引入。根因是**写侧从来没写出来过**（不是后来被删）：
  - `hibiki/lib/src/sync/desktop_lookup_service.dart:128` 声明 `void Function(String text)? onClipboardCaptured;`
  - `hibiki/lib/src/models/app_model.dart:4934` 赋值 `DesktopLookupService.instance.onClipboardCaptured = addClipboardHistoryEntry;`
  - **全仓零 `?.call()`**——回调被声明、被接上实现，但没有任何人触发它。
  引入 commit `24e6443bb`（2026-07-19，「剪贴板复制历史数据层与采集点」）；`git log -S onClipboardCaptured --all` 只有这一个 commit，其 diff 里该符号也只出现在声明行 + 赋值行。commit message 自称「采集点（origin=clipboard、去重通过后落历史）」，但代码里只留了个空插槽——读侧后续阶段全做了，回头没补写侧。
  写入链完整但断头：表 `clipboard_history` ← `replaceAllClipboardHistory` ← `_flush` ← `_schedulePersist` ← `ClipboardHistoryRepository.add` ← `AppModel.addClipboardHistoryEntry`(`app_model.dart:1412`) ← 只赋值给那个零调用的回调。
  读侧则**完全可达**：🕘 按钮无条件渲染于面板栏（`hibiki/assets/popup/global_lookup_host.js:494-511`）与瞬态浮窗（`:1157-1163`），Dart 两个 controller 都接（`clipboard_panel_controller.dart:547` / `global_lookup_controller.dart:495`），i18n 三个 key 齐备。于是用户每次点开都恒命中 `clipboard_history_empty` 空态，「清空」按钮也永远无事发生（清一张恒空的表）。属用户可见功能性缺陷，不是不可达残留。
  该路径**此前 0 测试覆盖**（`onClipboardCaptured` / `addClipboardHistoryEntry` / `clipboardHistoryRepo` 在 `test/` 与 `integration_test/` 零命中），这正是它潜伏至今而 CI 一直绿的原因。
- **[x] ① 已修复** — `hibiki/lib/src/sync/desktop_lookup_service.dart:215`（commit `c348f8345`）：在 `_queueLookupRequest` 的**去重通过点之后**补上唯一采集点 `onClipboardCaptured?.call(deduped)`，并用 `origin == DesktopLookupOrigin.clipboard` 收窄。
  - **单点收口即可**：`_queueLookupRequest` 全部 3 个调用方中，`dedupe: false` 的提前返回分支只有热键（`:404`，origin=hotkey）与悬浮字幕点词（`:453`，origin=explicit），两者压根到不了这一行；clipboard 来源（`submitText`）恒走去重分支。故不必在 `dedupe:false` 分支重复埋点，也不会误采热键查词 / 点词 / texthooker / gal hook 的文本。`origin` 判定是显式契约，防将来有别的来源改走去重分支时污染复制历史。
  - **落在去重之后**是关键：挖词 / 抓选区写回剪贴板的自触发回声被 `dedupeClipboard`（800ms 时间窗，BUG-1025）判 null 直接 return，因而不进历史；更上游还有 `clipboardIgnores.consume` 精确拦截 Hibiki 自产写入。同一段文本超窗口再复制则如实触发，仓库侧 `ClipboardHistoryRepository.add` 的「同文本去重到最新」把它移到队尾，不堆重复行。
  - 记的是 `deduped`——注音标记已剥（BUG-1138）、超长已截断（BUG-442）的纯基准文本，与本条链路其余消费面同一坐标系。
  - 顺带让 `debugReset()`（`:254`）清空该回调，避免用例间捕获器泄漏（生产侧不调 `debugReset`，行为不受影响）。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/desktop_lookup_service_test.dart` 新增 group「剪贴板复制历史采集 (BUG-1145)」6 项，**直接打在真实 `ClipboardHistoryRepository` + 内存 Drift 库上**（不是 mock 回调计数），覆盖：
  - 剪贴板复制的文本真的进仓库、且 `flushNow()` 后真有行落到 `clipboard_history` 表；查词管线不受影响（采集是旁路副作用）。
  - 多次复制不同文本按时间顺序累积（队尾 = 最新）。
  - **负向**：热键（`debugTriggerHotKey`）与悬浮字幕点词（`triggerLookup`）查词照常发生但**不写**复制历史；同一用例内再用 `submitText` 作正向对照，证明「空」不是装配没接上。
  - 去重窗口内的自触发回声不写进历史。
  - 超窗口重复复制同一文本去重到最新、不堆重复行（内存 + 落库双断言）。
  - 源码守卫：`AppModel` 仍把 `addClipboardHistoryEntry` 接到 `onClipboardCaptured`（钉住链路的另一半）。
  **负向验证已实测**：注释掉 `onClipboardCaptured?.call(deduped)` → 前 5 项全红；单独摘掉 `app_model.dart` 的赋值行 → 第 6 项红。两半各自可失效、各自有守卫。
- **备注**：
  - 该 group 用普通 `async test` 而非 `testWidgets`——`ClipboardHistoryRepository.add` 会起真实 debounce 刷盘 Timer，`testWidgets` 的 FakeAsync 收尾时会因「仍有 pending Timer」判红（该 Timer 由 tearDown 的 `repo.dispose()` 取消）。
  - 采集只在**桌面**发生（`DesktopLookupService` 是桌面剪贴板 + 全局热键触发器），移动端不受影响。
  - 未做真机验收：本修复的可观测面是单测已钉死的仓库/DB 写入；面板里 🕘 实际列出条目的目视确认留给用户在桌面 app 上完成。
