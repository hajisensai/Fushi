## BUG-5574 · TV 原盘按集展开的成员路径抽不出 PGS 轨，补字幕全部退回语音识别
- **报告**：2026-11-27（整库补字幕实跑报告：《BanG Dream! It's MyGO!!!!!》BD 上 / 下巻 13 集全部 `ocr: graphic track extraction failed`，改走本机语音识别）
- **真实性**：✅ 真 bug。这些条目的 `video_path` 是按集展开的虚拟成员路径（`BDMV/PLAYLIST/00000.p01.mpls`，盘上只有 `00000.mpls`）。`packages/fushi_engine/lib/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart` 的 `extractGraphicSubtitleTrack` 抽轨前先 `File(input.uri).stat()`，虚拟路径不存在 → `input missing` → 返回 false，根本没进 ffmpeg（后端本来会把成员路径改写成 concat 清单）。角度成员路径（`00001.a2.mpls`）同样中招。
- **[x] ① 已修复** — 蓝光成员路径不 stat 自身，改用 `resolveBluraySource` 读出背后的播放列表和片段：读不出或片段缺失才判 `input missing`，体积取各片段之和（只给非观察式后端算超时）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/bluray_angle_test.dart`「抽图形字幕轨认角度 / 分集成员路径」：角度成员路径能抽到后端；删掉该角度的片段后判 `input missing` 且不调用后端。
- **备注**：MyGO TV 版 13 集这次已用语音识别生成了字幕；修复进构建后对这 13 集重跑补字幕即可改用 PGS 识别（需要先撤销或删掉生成的字幕，否则判已覆盖）。
