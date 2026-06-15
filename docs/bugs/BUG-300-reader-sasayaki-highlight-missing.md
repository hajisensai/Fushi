## BUG-300 · 有声书文字跟随高亮在阅读器里完全不显示
- **报告**：2026-06-15（用户：截图证实音频在播、底栏显示当前句，但正文无任何高亮）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:3753`（修复前）—— reader 的 `_prepareSasayakiCuesJson` 手写内联循环构造给 JS 的 sasayaki cue payload，只放 `id`/`start`/`length`，**漏了 cue 原文 `text`**。

  数据流：`_prepareSasayakiCuesJson` → `_buildReaderSetupScript` → JS `window.hoshiReader.applySasayakiCues` → `collectSasayakiCueRanges`（`hibiki/lib/src/reader/reader_pagination_scripts.dart:506`）。该 JS 函数（BUG-060 改造）以 `cue.text` 为 `needle`，在**实时 DOM 的归一化全文**里就近、单调地重定位高亮区间；匹配时算出的 `start`/`length` 仅作「提示」。缺 `text` 时 `needle=''`、`normLen=0`，直接跳过 DOM 定位分支（`if(normLen>0)`），`resolved` 恒为 `-1` → 走回落分支，只按「匹配坐标系（package:html 解析的归一化偏移）」的 `start` 提示取区间。但该提示在「渲染坐标系（浏览器实时 DOM 归一化全文 map）」里逐字错位（正是 BUG-060 要消除的两坐标系不一致），`rangesForNormSpan` 据此映射出的 range 落空/落错 → 正文看不到任何有声书跟随高亮。

  对比：有声书桥接路径 `AudiobookBridge.buildSasayakiPayload`（`audiobook_bridge.dart:369`）payload **带 `text`**，所以其路径能正确高亮。两条路径汇聚到同一 JS 函数，却喂两份不同 payload —— reader 这一份漏字段就是无高亮根因。
- **[x] ① 已修复** —— `reader_hibiki_page.dart` 的 `_prepareSasayakiCuesJson` 删掉手写内联循环，改直接复用 `AudiobookBridge.buildSasayakiPayload(allCues, _currentChapter)`，与有声书桥接路径共用同一份必含 `text` 的 payload 契约，两条路径不会再各自漂移；并去掉 `buildSasayakiPayload` 的 `@visibleForTesting`（现有正式生产消费者）。提交：见本轮 commit。
- **[x] ② 已加自动化测试** —— 既有 `hibiki/test/media/audiobook/audiobook_bridge_payload_test.dart`（BUG-060）已断言 `buildSasayakiPayload` 每条 entry 含 `id/start/length/text` 且 `text==cue.text`；新增 `hibiki/test/pages/reader_sasayaki_payload_source_guard_test.dart` 源码守卫：断言 `_prepareSasayakiCuesJson` 复用 `buildSasayakiPayload`、不再手写漏 `text` 的内联 payload map（撤修复退回手写循环则转红）。
- **备注**：不破坏 BUG-282 单调游标（逻辑在 JS `collectSasayakiCueRanges`，本次不动）；不破坏普通查词高亮（查词走独立 `::highlight` priority + composeOpaqueColor 路径，与 sasayaki cue 无关）。
