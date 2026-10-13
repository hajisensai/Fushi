## BUG-3306 · 查词页搜索框 X 清不掉结果（反馈 DUiNPr1J10，未复现）
- **报告**：2026-10-13（用户：应用内反馈 #DUiNPr1J10，Android 2.10.0-debug.18749）
- **真实性**：❌ 未复现，判为对反馈复现步骤的误读。原文「触发：在查词的时候并且查完了不能点X清掉，就这个页面，侧边返回一下就会出现同步进行中」是在描述 BUG-3305 的触发条件——查完**不要**点 X（点了 X 查询就清空，查词页 PopScope 不再拦返回，也就触发不了那个对话框），直接侧滑返回。截图 s1 是「返回前的页面」，s0 是返回后：查询已被查词页 PopScope（`home_dictionary_page.dart:635–643`）清掉、同时弹出同步告警，正好对上。
  沿真实路径核 X：`FushiSearchField._trailing`（`fushi/lib/src/utils/components/fushi_material_components.dart:1020`）的清除钮 → `onClear: _clearSearch`（`home_dictionary_page.dart:924`）→ `_resetQuery`（550–573）清 controller、`_result`、去抖计时器、代号自增。临时 widget 探针在 Android / Windows 两种平台变体 × 自动查词开/关四种组合下挂真实 `HomeDictionaryPage`：查完（结果已显示）后点 X，搜索框为空、结果区消失、X 消失，四组一致；在途查询被清的情况已有 `home_dictionary_pull_preserve_query_test.dart`「clearing invalidates an in-flight search result」覆盖。
- **[ ] ① 无需修复（未复现）** —
- **[ ] ② 未加测试（未复现条目，不计勾选）** — 探针未入库，现有 `home_dictionary_pull_preserve_query_test.dart` 已钉住清除路径。
- **备注**：没在真机上验证 vivo 输入法的组字态；若用户补充「点了 X 文字又回来」的录屏，再按 IME 组字态方向查。
