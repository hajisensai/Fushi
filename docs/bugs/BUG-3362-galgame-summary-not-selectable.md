## BUG-3362 · galgame 详情简介不能选择复制
- **报告**：2026-10-14（用户：反馈 2DmrXg-wtD，Windows，「刮削元数据以后游戏简介不能复制」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/galgame_detail_page.dart:1136` 简介正文与 `_summarySection` 的值（别名 / 全部标题 / 发行日等）都是普通 `Text`，不可选择。
- **[x] ① 已修复** — 简介正文与资料值改 `SelectableText`（无简介时的占位文案仍是 `Text`）。提交 d8830baef6（分支 `cc/fb-misc-ui`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/galgame_detail_page_test.dart`「简介 tab」断言简介与别名是 `SelectableText`。
- **补漏（2026-10-16）**：d8830baef6 漏了同页另外两处刮削纯文本——Hero 标题 / 开发商（`_heroInfo`）与资料网格文本值（`_metaTextCell`：添加时间 / 排行等）仍是 `Text`，开发商在全页没有任何可复制的位置。两处改 `SelectableText`；同一测试补断言 Hero 标题、开发商与「添加时间」值是 `SelectableText`。
- **备注**：截图里 VNDB 简介带原始 BBCode（`[url=...]...[/url]`），是另一个显示问题，未在本条处理。
