## BUG-2996 · 待发卡片页首次读表失败时骨架屏永不结束且无重试
- **报告**：2026-10-06（Codex 第六轮审查 HBK-AUDIT-044，第七轮故障注入升级为已复现；复现 `fushi/test/anki/pending_mines_load_error_repro.dart`，分支 `codex/sh-style-review-1006`；引入于 `40e8ae22ecbe`）
- **真实性**：✅ 真 bug（根因：`fushi/lib/src/anki/pending_mining/pending_mines_page.dart:155` `reload()` 只在 `store.all()` 成功后置 `_loaded = true`，没有 catch / 错误状态；首次读表抛异常时异常逃逸为未处理错误，`_buildBody`（`:323`）因 `!_loaded` 永远返回骨架，页面无错误说明也无重试入口）
- **[x] ① 已修复** — `reload()` 捕获异常记 ErrorLogService，置 `_loaded = true` + `_loadError`；`_buildBody` 在有错且无已有数据时显示共享 `FushiPlaceholderMessage`（`FushiPlaceholderTone.error`、`t.error_load_failed`、折叠原始错误）+ 重试按钮（回到骨架重读）；已有数据时刷新失败保留旧列表
- **[x] ② 已加自动化测试** — `fushi/test/anki/pending_mines_load_error_test.dart`（真实 PendingMinesPage + AppModel + 内存 Drift，拦截器只让 pending_mine_queue 的 SELECT 失败：空队列对照；失败 → 无骨架、无逃逸异常、error 色调占位 + 重试，撤故障后点重试回空态；2 例）
- **备注**：
