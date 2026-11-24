## BUG-5404 · 绘光大字发虚
- **报告**：2026-11-24（用户：Windows 桌面全屏歌词、约 2000px 宽屏，「绘光样式字体不够清晰」，截图里主行焦点字约 120 逻辑 px、背景回声大字更大，边缘明显发虚）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_scene.dart:232-289`（修前）：`LumiereGlyphAtlas.build` 把整首歌的字一律按固定 `_em = 64` 图集像素画进一张白字图集，不看屏上字号也不看 devicePixelRatio；绘制时（修前 :1640 回声词、:1864 歌词窗口、:2002 / :2034 片尾卡）用 drawRawAtlas 按 `px * _cell / _em` 放大。焦点字 `heroSize·h`（约 0.085h，受 fontScale）在 1100 逻辑 px 高的窗口上约 90～120 px，回声词 `echoSize·h·(0.25..0.75)` 可到 0.255h ≈ 280 px，再乘 DPR，等于把 64 px 的位图放大 2～6 倍。
  - 量化（`flutter test` 真实像素，Noto Sans JP 149 个不同字，屏上 240 px，数 alpha 介于 10%～90% 的边缘过渡像素）：「夜」修前 1167 / 修后 254 / 直接排字 135；「愛」1461 / 437 / 340；「る」851 / 196 / 108——修前过渡带是直接排字的 4～9 倍。
- **[x] ① 已修复** — 新文件 `lumiere_glyph_atlas.dart`：图集按屏上**物理**字号分档（em = 64、128、256… 物理像素，顶档按单档 4096² 像素预算与 512 封顶），每个字取不小于其物理字号的最小一档（只缩不放；小字不从大档一路缩出锯齿）；最低档建场景时同步画，更高档在画面上第一次出现那么大的字时后台分片排字 + 异步 `toImage` 补上，就绪前用已有最近一档。一档拆成 ≤1024² 的若干页，每页单独光栅化，raster 线程不会一口气画几千万像素。`LumiereFrame.devicePixelRatio` 由 `MediaQuery.devicePixelRatioOf` 传入。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/visualizer/modes/lumiere_glyph_atlas_test.dart`：「清晰度」组用真实像素断言 240 px 大字修前过渡带 > 直接排字 2.5 倍、补档后 < 修前一半且 ≤ 直接排字 2.2 倍；分档预算、按物理像素选档（DPR 3）、分页取页。
- **备注**：未在 Windows 真机全屏歌词肉眼复测（子代理环境无法开 app 截图），待补设备截图对比。
