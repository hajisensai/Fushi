## BUG-4728 · 英文 EPUB 未声明排版方向时被套成全局竖排，拉丁字母整行侧躺
- **报告**：2026-11-16（应用内反馈 EwmiUOMTS-：Windows 正式版读英文 EPUB，正文按 vertical-rl 竖排，拉丁字母整行侧躺）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/epub/book_original_layout.dart:50`（develop ff9ccbfc8b）：「跟随原书」的 `BookOriginalLayout.resolve` 只在 OPF 写了 `primary-writing-mode` 或 spine `page-progression-direction` 时才给出书本方向；英文 EPUB 通常两项都不写，结果是 `none`，阅读器回落全局排版方向，而全局默认是 `vertical-rl`（`fushi/lib/src/reader/reader_settings.dart:440`）。`resolve` 已经拿到 `dc:language`，却只在 `ppd=rtl` 时用来区分阿拉伯 / 希伯来文，没声明方向时完全不参与推断。
- **[x] ① 已修复** — `BookOriginalLayout.resolve` 在两项方向元数据都没写时退到 `dc:language`：主子标签是合法 2～3 位字母码、不是 `und` / `mul` 等特殊码、也不属于可竖排语言（中日韩各语种、汉文、蒙古文、阿伊努 / 琉球语）时，推横排，翻页方向按书写方向（阿拉伯 / 希伯来文等 rtl，其余 ltr）。可竖排语言、未声明语言、写成语言名之类认不出的取值仍为 `none`，照旧用全局设置；书里声明了方向时语言不改写它。仍在「跟随原书」开关之下，关掉即回全局值。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_original_layout_test.dart`：纯函数层（en / en-US / FR / de_DE / eng → 横排 + ltr，ar → 横排 + rtl；ja / zh-Hant / ko / jpn / mn / und / mul / Japanese / 空 → none；声明了方向时语言不改写）与 EpubParser 层（真实 OPF `dc:language=en`、无方向元数据 → 横排 + ltr）。修复前 2 条红。
- **备注**：真机 / 三种 view mode 未复测（修复只改变书本排版覆盖值，渲染走既有横排路径）。
