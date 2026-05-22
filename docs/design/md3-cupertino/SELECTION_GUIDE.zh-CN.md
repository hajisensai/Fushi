# Hibiki MD3 + Cupertino 选择指南

这份指南是给最终挑方案用的入口。图片已经覆盖当前所有 UI 设计面：84 个界面/支撑组件，每个都有 A/B/C 三张示例图，总计 252 张。现在不要再盲目加图，先选基准，再只改例外。

## 先选整包方案

先打开 [pack-selection-index.html](pack-selection-index.html)。它把 4 套整包都展开成 84 个界面/支撑组件的完整视图。想先快速扫风格，再打开 [design-pack-gallery.html](design-pack-gallery.html) 看每套 12 张代表图。想按单个界面横向对比 A/B/C、四套整包默认选择，并直接点选导出最终文本，打开 [interface-pack-comparison.html](interface-pack-comparison.html)。想用 Markdown 一页审完整 84 行，打开 [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md)。

| 方案 | 适合场景 | 主要风险 |
| --- | --- | --- |
| `MD3 Practical` | 想要最低实现风险、Android 原生感、控件直接清楚。 | 阅读器和设置页会偏工具化，不够安静。 |
| `Reading Calm` | 想要阅读器、词典、设置更安静，更像长期阅读应用。 | 字典管理、Anki、标签这类重操作页可能不够密。 |
| `Adaptive Power` | 想要桌面/平板优先、分栏、检查器、批量操作效率。 | 手机阅读会显得太重，阅读器通常要改例外。 |
| `Hibiki Balanced` | 推荐默认。阅读保持安静，管理页保持密度，共享组件统一。 | 不是纯 A/B/C 单一风格，后续实现必须用严格 token 控住一致性。 |

当前推荐选 `Hibiki Balanced`，不是因为它“平均”，而是因为 Hibiki 既是阅读器，也是词典、Anki、标签、导入管理工具。把所有页面都做成同一种软风格或同一种控制台风格，都不符合真实使用。

## 再改关键例外

打开 [interface-pack-comparison.html](interface-pack-comparison.html)，按下面顺序看。它会在同一张卡里显示该界面的 A/B/C 三张图，以及 `MD3 Practical`、`Reading Calm`、`Adaptive Power`、`Hibiki Balanced` 各自默认选哪张。先点页面顶部的整包按钮加载基准，再只在需要改的界面点 `选择 A/B/C`；本页会自动标记该界面已审、保存选择、支持 `只看未审` 和 `跳到下一个未审`，并生成可复制的最终文本。别从 84 行第一行一路机械点，那是浪费时间。

| 优先级 | 先看这些界面 | 判断标准 |
| --- | --- | --- |
| 1 | `reader_hoshi_page.dart`, `display_settings_page.dart`, `audiobook_play_bar.dart`, `lyrics_dialog_page.dart` | 阅读时是否安静；播放栏、查词、歌词是否不会压正文。 |
| 2 | `home_dictionary_page.dart`, `dictionary_result_page.dart`, `dictionary_popup_layer.dart`, `dictionary_popup_webview.dart` | 查词结果是否适合浏览，而不是总把焦点拉回输入框。 |
| 3 | `dictionary_dialog_page.dart`, `dictionary_dialog_import_page.dart`, `dictionary_settings_dialog_page.dart` | 管理词典、导入、CSS、音频源时是否够密、够明确。 |
| 4 | `anki_settings_page.dart`, `audio_recorder_page.dart`, `text_segmentation_dialog_page.dart`, `crop_image_dialog_page.dart` | 制卡和 Anki 映射是否能高效反复操作。 |
| 5 | `home_page.dart`, `home_reader_page.dart`, `reader_hoshi_history_page.dart`, `collections_page.dart` | 首页、书架、收藏是否扫一眼就知道状态和下一步。 |
| 6 | `debug_log_page.dart`, `error_log_page.dart`, `websocket_dialog_page.dart`, shared/support 组件 | 日志、错误、弹层、空状态是否诚实，不伪装成功状态。 |

如果某行不确定，保留基准默认。特殊情况越多，后续实现越容易变成页面级补丁。好设计应该让大多数页面继承同一套选择。

## 输出给实现的格式

推荐直接从 [interface-pack-comparison.html](interface-pack-comparison.html) 顶部复制最终选择文本，保存成 `my-final-selection.txt`。如果你更想手写，再从 [FINAL_SELECTION_TEMPLATE.zh-CN.md](FINAL_SELECTION_TEMPLATE.zh-CN.md) 开始。生成器会严格检查未知行，拼错界面名会失败，不会静默生成假规格。

整包选择用下面这种：

```text
Pack: hibiki-balanced
```

单界面例外用下面这种：

```text
reader_hoshi_page.dart: B
dictionary_dialog_page.dart: C
home_page.dart: C
```

然后生成规格：

```powershell
node .\generate-implementation-spec.mjs --picks .\my-final-selection.txt --output .\IMPLEMENTATION_SPEC_FINAL_DRAFT.md
```

如果暂时没有例外，直接用推荐规格：

```powershell
node .\generate-implementation-spec.mjs --pack hibiki-balanced --output .\IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md
```

## 当前交付状态

- [pack-selection-index.html](pack-selection-index.html): 4 套整包方案的逐界面索引，每套都能跳到完整 84 图选择页。
- [interface-pack-comparison.html](interface-pack-comparison.html): 按界面横向比较 A/B/C 三图，显示四套整包默认选择，并支持点选、已审/未审队列、保存和复制最终选择文本。
- [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md): 84 个界面的 Markdown 总表，逐行列出三张候选图、四套整包默认和推荐选择。
- [FINAL_SELECTION_TEMPLATE.zh-CN.md](FINAL_SELECTION_TEMPLATE.zh-CN.md): 最终选择填写模板，可直接生成最终规格草案。
- [selection-md3-practical.html](selection-md3-practical.html) / [SELECTION_MD3_PRACTICAL.zh-CN.md](SELECTION_MD3_PRACTICAL.zh-CN.md): `MD3 Practical` 的 84 个界面完整展开。
- [selection-reading-calm.html](selection-reading-calm.html) / [SELECTION_READING_CALM.zh-CN.md](SELECTION_READING_CALM.zh-CN.md): `Reading Calm` 的 84 个界面完整展开。
- [selection-adaptive-power.html](selection-adaptive-power.html) / [SELECTION_ADAPTIVE_POWER.zh-CN.md](SELECTION_ADAPTIVE_POWER.zh-CN.md): `Adaptive Power` 的 84 个界面完整展开。
- [design-pack-gallery.html](design-pack-gallery.html): 4 套整包方案，每套 12 张代表图。
- [recommended-selection-hibiki-balanced.html](recommended-selection-hibiki-balanced.html): 推荐 `Hibiki Balanced` 方案的 84 个界面可视化总览。
- [RECOMMENDED_SELECTION_HIBIKI_BALANCED.zh-CN.md](RECOMMENDED_SELECTION_HIBIKI_BALANCED.zh-CN.md): 推荐 `Hibiki Balanced` 方案的逐界面中文表。
- [interface-images/index.html](interface-images/index.html): 84 个界面/组件，每个 A/B/C 三张图，可逐项选择。
- [INTERFACE_PICKS.md](INTERFACE_PICKS.md): 可复制填写的 84 行选择表。
- [IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md](IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md): 当前推荐方案的实现规格草案。
- [IMPLEMENTATION_SPEC_DRAFT.md](IMPLEMENTATION_SPEC_DRAFT.md): manifest 默认选择的规格草案，等用户最终选择后会被重新生成。

## 不要做的事

- 不要为了“统一”把阅读器、词典管理、Anki 映射全部压成同一种布局。
- 不要改当前 Hoshi 阅读器路径到旧 TTU。`reader_ttu`/`Ttu*` 只说明兼容或迁移边界。
- 不要在实现阶段按页面随手堆装饰。先做 token 和共享组件，再落到页面。
- 不要把未确认选择写进运行时代码。选择没定，代码就不该开始乱动。

## 下一步确认问题

请先确认一个基准：

```text
我选 Pack: hibiki-balanced
```

或者改成：

```text
我选 Pack: reading-calm
例外：
dictionary_dialog_page.dart: C
anki_settings_page.dart: C
```

确认后，下一步才是把最终选择重新生成成实现规格，并写具体 Flutter 实施计划。
