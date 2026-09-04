## BUG-2117 · 快捷键设置页 scope 卡片顺序是枚举累加顺序而非通用→页面→设备
- **报告**：2026-09-04（用户：「感觉这个快捷键描述的排版有点问题。阅读器过了之后是首页，然后全局，返回退出，有声书」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/shortcut_settings_page.dart:336` 直接 `for (scope in ShortcutScope.values)` 投影卡片，顺序完全由 `fushi/lib/src/shortcuts/shortcut_action.dart:1` 的枚举声明顺序决定；而该枚举是按加入时间累加的（reader / home 最早，global 次之，universal 后插，video / manga / gamepad / globalExternal / dictionaryPopup 依次追加），页面就排成「阅读器 → 首页 → 全局 → 返回·退出 → 有声书 → 视频 → 漫画 → 手柄 → 全局（应用外）→ 查词弹窗」，既不是通用在前也不是按使用频率，纯粹是 git 时间线。scope 没有任何地方按 index 持久化或解析（偏好存名字、`coactiveScopes` 用显式列表、冲突检测不读枚举位置），所以顺序只影响显示。
- **[x] ① 已修复** — 不另加显示顺序表（那是第二份真相源），直接把枚举声明顺序改成「跨页面通用（global / universal / globalExternal）→ 各页面（home / reader / audiobook / manga / video）→ 输入设备（gamepad）→ 查词弹窗」，并在枚举文档注释里写明「声明顺序就是设置页顺序」。提交 `HASH_FIX`。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/shortcut_scope_order_test.dart`：`orderedEquals` 钉住全序，新增 scope 必须落进对应分组而不是追加到末尾（已变异实测：交换 home / reader 即红）。
- **备注**：`visual_settings_page_guard_test` 要求页面必须遍历 `ShortcutScope.values`，本修复与之兼容。
