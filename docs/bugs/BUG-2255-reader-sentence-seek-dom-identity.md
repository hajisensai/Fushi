## BUG-2255 · 正文从本句播放误取上一条字幕
- **报告**：2026-09-07，用户提供《86》第一卷 SRT 与 EPUB，正文从本句播放偶尔跳到上一句。
- **真实性**：✅ 真 bug。`reader_selection_scripts.dart:1769` 的 `getNormalizedOffset` 返回学习单位数，旧 `reader_fushi/audiobook.part.dart:895` 的 `_findCueForOffset` 却把它当成字幕归一化字符偏移。数字、英文串分别按一个词与多个字符计数，导致选择位置向前漂移。`reader_fushi/lookup.part.dart:228` 和 `reader_fushi/chrome.part.dart:738` 两处消费受影响。
- **[x] ① 已修复** — 点词、拖选和原生选区回传实时 DOM 对应的 cue 标识，Dart 通过既有 `cueForPointerPayload` 解析。复用正文高亮的实际映射，删除混用坐标的查找；中键共享同一 DOM 查询，并将 Range 末端排除出前句。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audio_cue_identity_test.dart`、`reader_audio_cue_identity_harness.mjs`：真实 Chrome 中执行两种生产 shell 的 reader 对象及 selection 脚本，共 24 个场景，包含数字/英文、点选/原生选区、句首、ruby、合成 cue 和无 cue；`reader_selection_data_test.dart` 覆盖桥接解析。定向 10 项、相邻 90 项通过；全量 `flutter analyze --no-pub` 无问题。
- **真实输入证据**：9533 条字幕中匹配 9487 条。第 17 条 `02:02.845` 的匹配起点为 83，学习单位起点却为 73，落入第 16 条 `02:00.563`。序章同一文本节点中的 `ＲＭＩ Ｍ１Ａ４` 与 `ＯＳ Ｖｅｒ８．１５` 累积少计 10。第 18 条也错落第 17 条。真实文件 matcher 探针 1 项通过；本地证据 `.codex-test/86-probe.json`，原书正文不入库。
- **备注**：上述浏览器测试验证 DOM→选区→cue 标识，未运行完整 Windows App 的原始点击到实际音频起音 E2E；用户本次只提供 SRT/EPUB。学习统计、收藏/制卡的现有偏移字段和字幕匹配结果不在本次变更范围。独立分支交集成负责人合入，未修改原工作区。
