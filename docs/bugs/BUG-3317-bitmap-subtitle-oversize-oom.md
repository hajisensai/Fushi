## BUG-3317 · 位图字幕对象声明超大尺寸时一次分配数GB平面
- **报告**：2026-10-13（审查 BUG-3273~3276 合并时 codex 审查发现，源码复核属实）
- **真实性**：✅ 真 bug。PGS ODS 的宽高（`packages/fushi_engine/lib/media/video/bitmap_subtitle/pgs_subtitle_parser.dart` `_readOds`）与 DVB RCS 的区域宽高（`dvb_subtitle_decoder.dart` `_readRcs`）都是 u16，解析时照单全收；渲染时 `decodePgsRle` / `DvbRegion.render` 直接 `Uint8List(width * height)`。损坏或恶意字幕声明 65535×65535 就是一次 4 GB 分配，整轨 OCR / 逐句时间表 / 遮蔽层（以及无头服务端互联导出）都会走到，进程 OOM。PGS 一支是搬进引擎前就有的旧问题，DVB 一支随 BUG-3276 新增。DVD 坐标只有 12 bit（≤4096²），不受影响。
- **[x] ① 已修复** — 根因在解析入口没校验码流声明的尺寸：新增 `kBitmapSubtitleMaxDimension = 4096`（BD PGS 与 DVB 对象均不超过它）与 `isDecodableBitmapSubtitleSize`（`bitmap_subtitle_cue.dart`）；PGS `_readOds` 遇越界尺寸丢掉该对象（连同同 id 旧对象与未拼完的分片），DVB `_readRcs` 丢掉该区域，`decodePgsRle` 同判据返回 null。提交 `fix(video): bitmap subtitle size limit + OCR card on shared floating surface (BUG-3317, BUG-3318)`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/bitmap_subtitle/bitmap_subtitle_size_limit_test.dart`（判据边界、PGS 65535² 不解码、DVB 超大区域不出 cue 而正常区域照出）。
- **备注**：判据只按规范上限丢损坏数据，正常 4K 字幕不受影响。
