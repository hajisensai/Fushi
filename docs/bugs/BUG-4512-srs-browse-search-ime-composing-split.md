## BUG-4512 · 浏览页搜索框把输入法组字中间态当提交值：Windows 中文输入法组字被拆
- **报告**：2026-11-15（应用内反馈 D2hILRLlPT）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/pages/implementations/srs/srs_browse_page.dart:572-595`（修前）`_onDraftChanged` 只拿到
    `onChanged` 的纯文本，不看 `TextEditingValue.composing`。Windows 中文输入法组字时拼音以 composing 区间进控制器，
    分音节带空格（`ni hao`）：一次多进来几个字 + 含空白，被「粘贴整段拆成积木」的判断当成粘贴，草稿被
    `_draft.clear()` 清掉，组字被打断。即使不拆，组字中的拼音也按 200 ms 去抖进查询（`_draftQuery` / 补全读
    `_draft.text`）。
  - 另一面：日文输入法回车确认时常常只清 composing、文本不变，`TextField.onChanged` 不报，只靠 `onChanged` 驱动的
    草稿永远拿不到「组字结束」这一下。
- **[x] ① 已修复** — 草稿的提交值改由控制器监听（`_onDraftValue`）按整份 `TextEditingValue` 推进：composing 非空时
  不动；组字结束（含只清 composing）才把文本作为提交值处理。查询（`_draftQuery`）与补全只读提交值 `_lastDraft`；组字确认
  进来的一段字不当粘贴、不拆积木。程序清空草稿的几处先复位提交值再清控制器。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_browse_ime_and_inline_edit_focus_test.dart`「搜索框组字中的中间态…」：
  经 `testTextInput.updateEditingValue` 送带 composing 的拼音（含空格），断言不拆积木、控制器原样保留组字、列表不按中间态
  筛；选定候选后按提交值筛；日文式「只清 composing、文本不变」的确认也触发筛选。
- **备注**：真 Windows 中文输入法的手测未做（widget 层已按引擎送来的同一形状的 `TextEditingValue` 覆盖）。
