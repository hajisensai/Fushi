## BUG-1425 · MD3 守卫豁免与实际命中脱节：四处裸 Material chrome 静默放行 + fontSizeFactor 绕过判据 + 过期豁免
- **报告**：2026-08-02（TODO-2629 / 2630 / 2631，PR#707 排查时发现，当时有意未动）
- **真实性**：✅ 真 bug（三类都复核成立）

`hibiki/test/settings/md3_design_system_static_test.dart` 的
`ordinary page chrome does not reopen local MD3 decisions` 是全 `lib/src` 子串扫描 +
**整文件**豁免（`allowedFiles`：命中任一禁用 token 时，只要该文件有一条 reason 就整份放行）。
这个「理由是散文、豁免是整文件」的结构漏了三类东西：

### A 类（TODO-2629）豁免写得比实际命中宽 —— 理由没覆盖到的部分被静默放行
整文件豁免下，**理由里没提到的那部分违规是看不见的**：主守卫永远不会为这些文件报错，
光读 allowlist 也看不出理由与代码已经对不上。四处实测成立：

| 位置 | 实际命中 | 豁免理由只覆盖 |
|---|---|---|
| `hibiki/lib/src/media/video/video_chapter_panel.dart:114` | 裸 `ListTile(` | 「行字号随 appUiScale 缩放」；且它援引的同类 `video_subtitle_jump_panel.dart` 根本不用 `ListTile`（手搓 `InkWell`+`Container` 行） |
| `hibiki/lib/src/pages/implementations/texthooker_page.dart:178,647` | 两处裸 `ListTile(`（选轨对话框 / 窗口选择对话框） | 「hook 状态胶囊是实时内容指示器」 |
| `hibiki/lib/src/pages/implementations/video_shader_dialog.dart:602` | 裸 `ListTile(`（Anime4K 预设选择列表） | 「导入的 shader 文件以勾选行列出」（即 :365 / :505 两处 `CheckboxListTile`） |
| `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:1837` | `SwitchListTile(`（「一并下载字幕」**设置开关**） | 通篇只讲候选行 / 字幕行 / 任务行等**内容行**，从没提过开关 |

处置：**收口，不是把理由改宽去追认现状**（那等于事后合法化）。四处全部改走共享 MD3 组件
（`HibikiListItem` / `AdaptiveSettingsSwitchRow`，与 PR#698、`games_library_page` 同款收口）。
`HibikiListItem` 补了 `autofocus`——`texthooker` 窗口选择器的 BUG-1049 焦点驱动行为
（「打开即落在正确的窗口上，回车就绑」）靠它，收口时不能悄悄丢掉。

### B 类（TODO-2630）真盲区 —— 换个写法就绕过判据
根因 `hibiki/lib/src/utils/components/clipboard_lookup_text_panel.dart:111-114`：

```dart
return base.apply(
  fontSizeFactor: (_dictionaryHeadwordBaseFontSize / safeBaseSize) * safeScale,
);
```

**读一个排版令牌（`tokens.type.pageTitle`）只为把它整除掉**，最终字号恒等于 `26 * scale`。
两宗罪：① 整个文件一个 `fontSize:` 都不剩（`grep -c "fontSize:"` = 0），子串判据天然扫不到，
等于给绕过留了正门；② 谁把 `pageTitle` 调大，因子自动补偿回 26，改动零反馈、静默失效。

复核后**这个 26 本身是合理的**：BUG-175 / TODO-222 要求源文本条与查词弹窗 headword 同级，
而那个 headword 不是 Flutter 排版角色，是 WebView 里 `hibiki/assets/popup/popup.css` 的
`.expression { font-size: 26px }`。所以它是**跨边界对齐常量**，不是本地重新拍板的 MD3 字号。
处置：停止伪装——明写 `fontSize: kPopupHeadwordFontSize * safeScale`，常量文档化说明它对齐谁，
allowlist 记这条 reviewed 理由，并用可证伪断言把它与 popup.css 钉在一起（改哪边都红）。
判据侧补 `fontSizeFactor` / `fontSizeDelta`（`TextStyle.apply` 的两个字号旋钮）。
扩判据后全仓重扫：`lib/src` 里 `fontSizeFactor` 只此一处、`fontSizeDelta` 零处，无新增违规。

### C 类（TODO-2631）过期豁免 —— 理由早与代码脱节，却仍给整文件免检
`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的豁免理由写的是
「shellScript 收到 `fontSize: s.fontSize.round()`」，实测该文件**零禁用 token 命中**
（`shellScript` 这个符号在整个 `lib/src` 里也已不存在）。加上结构性检查后又扫出**同类 14 条**，
全部经复核零命中：`hibiki_dropdown` / `adaptive_theme` / `global_lookup_render` /
`media_item_dialog_page` / `reader_quick_settings_sheet` / `video_side_panel` /
`video_danmaku_overlay` / `dictionary_dialog_import_page` / `dictionary_dialog_delete_page` /
`cupertino_settings_renderer` / `hibiki_list_tile` / `hibiki_text_selection_controls` /
`update_checker_ui` / `reader_pagination_scripts`。
（典型：`hibiki_list_tile.dart` 的理由是「Legacy compatibility adapter wraps framework
ListTile」，但它早已改成委托 `HibikiListItem`，一个框架 `ListTile` 都不剩。）
这些不是无害的死条目——它们是**给未来的违规预留的、不会被审的通行证**：哪天有人往
`hibiki_list_tile.dart` 塞真 chrome，守卫会照旧放行。处置：15 条全删。

- **[x] ① 已修复** — A 类四处收口共享 MD3 组件 + `HibikiListItem.autofocus`；B 类去掉
  `fontSizeFactor` 洗白改明写对齐常量；C 类删 15 条过期豁免。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/md3_design_system_static_test.dart`
  三条新守卫（均已变异实测）：
  - `reviewed content exemptions do not silently cover bare chrome`：把 A 类四处逐条钉成
    可证伪断言，判据复用主守卫同一个标识符边界原语 `_containsForbiddenChrome`（不是另写
    一套宽松子串）。四处各自改回裸 chrome 都能让它红。
  - `source lookup strip headword size stays pinned to the popup CSS`：把「对齐弹窗
    headword」从散文钉成断言——Dart 常量必须等于 `popup.css` 里 `.expression` 的真实
    px 值，且不许退回 `fontSizeFactor` / `fontSizeDelta`。两个方向（改 Dart / 改 CSS）都红。
  - `ordinary page chrome …` 新增 `deadAllowlistEntries` 断言：任何豁免条目一旦零命中
    （或文件没了）立刻红，C 类这种「理由漂走、整文件免检」不会再攒下来。
  - 判据本体新增 `fontSizeFactor` / `fontSizeDelta` 两个禁用 token（B 类绕过口）。
- **备注**：本次**没有**放宽任何断言、没有 skip、没有把文件移出扫描范围；A 类也没有把豁免
  理由改宽去追认现状。`video_shader_dialog` 的豁免保留 `CheckboxListTile` 部分，并加了
  「那两处勾选行必须还在」的正向断言——理由所依附的事实消失时，理由必须重写而不是继承。
