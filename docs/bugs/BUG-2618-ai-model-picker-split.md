## BUG-2618 · AI 提供商：模型候选是字段外的第二个下拉，选完「模型」输入框不跟着变
- **报告**：2026-09-21（用户：录屏 `2026-09-21 23-16-19.mp4` + 截图，原话「交互很反直觉」「只是点击获取列表模型这一行才出现，选完之后就会把模型那样的值替换掉」）
- **真实性**：✅ 真 bug。同一个「模型」值挂了**两个输入控件**——`fushi/lib/src/pages/implementations/ai_provider_settings_section.dart:216`（`SettingsFormField` 吃 `initialValue`，只认第一次 build）和它外面另起一行的
  `DropdownButtonFormField`（旧 `ai-provider-$index-model-picker`）。下拉的 `onChanged` 只改草稿，不动输入框，于是：
  - 录屏第 19 帧：下拉显示 `deepseek-flash`、上面的输入框仍显示 `deepseek-v4-pro`，**界面两处各说各话**，而真正落盘的是用户没在看的那一个（重进页面才对上，观感就是「把模型的值替换掉了」）；
  - 那行下拉只在拉过一次列表之后**凭空出现**，把已有字段的间距顶开（截图里输入框文字被下拉边框压住）；
  - 它的 `labelText` 又用了 `t.ai_provider_models_fetch`，和下方按钮同名「获取模型列表」——一个动作名当了一个字段名。
- **[x] ① 已修复** — `aff83a045e1`：删掉字段外那一行下拉，候选改成贴在「模型」字段尾部的箭头按钮（`InputDecoration.suffixIcon`，新增 `SettingsFormField.suffixIcon`）。一个值只留一个输入控件：字段改由按 `draft.id` 持有的 `TextEditingController` 驱动，挑中的候选**写进同一只 controller**，所见即所存。箭头在没拉过列表时自己先拉一次（用户点它的意思就是「给我看有哪些模型」），地址还不是合法 URL 时置灰，拉取中显示转圈，拉失败不弹空菜单（原因仍在下方探测结果那行）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/ai_provider_settings_test.dart`「候选选择器：没拉过先拉，选中即同时改字段显示与落盘」：断言 ① 选择器是「模型」字段的**后代**（挡住「候选又被挪到字段外面」的回潮）；② 没点过「获取模型列表」也能直接挑；③ 选完 `prefs.aiProviders.single.model` 与**输入框 controller 的文本**同时变成新值。第 ③ 条是回归点——把字段退回 `initialValue` 后这条立刻红。
- **备注**：`ai_provider_model_hint`（「可留空，再点下方拉取列表」）与「获取模型列表」按钮都保留：按钮仍是拉一次并报「找到 N 个模型」的显式入口，箭头只是就地挑。
