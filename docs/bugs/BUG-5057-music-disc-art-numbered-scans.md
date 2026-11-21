## BUG-5057 · 音乐 CD 盘面图认不出只有编号的扫图（`Scans/01.webp`、`BK/Scan 120.jpg`）
- **报告**：2026-11-21（用户：「我的 cd 盘面还是没有」，附音乐页截图）
- **真实性**：✅ 真 bug。盘面识别只看文件名（`fushi/lib/src/media/music/music_disc_art.dart` 的 `musicDiscArtScore`：文件名 / 子目录名里要有 `disc` / `cd` / `label` / `盘面` 等词）。用户曲库里所有带扫图的 CD（VCB-Studio / EAC 抓轨，19 个扫图目录）文件名全是编号——`Scans/01.webp … 08.webp`、`Scans/SCAN_06.webp`、`BK/Scan 120.jpg`——一张都认不出，`MusicDiscArtIndex` 结果为空，专辑墙 / 继续收听 / 光盘分区都不画唱片。另有 EAC 习惯的 `BK/` 扫图目录不被当成扫图收纳目录。K-ON!! OST Vol.1 目录里只有 `cover.jpg` / `folder.jpg`，本来就没有盘面扫描，不在此列。
- **[x] ① 已修复** — 文件名认不出时，扫图收纳目录里的图按内容判（`isMusicDiscFace`：近似正方形、四角均匀背景、中心孔透出背景、盘缘内外反差），判据在用户真实扫图上标定：19 个目录的盘面全中，圆形 INDEX 内页、特典卡、托盘照、跨页均不中。解码走引擎降采样（`sampleMusicDiscFace`，96×96），先读图头、非方图不解码。`BK` 整名算扫图目录。按内容认出的得分（90）低于文件名认出的，同时存在时文件名优先。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_disc_art_test.dart`：合成光盘 / 非光盘像素样本的 `isMusicDiscFace` 判定、候选筛选与自然序、`BK` 目录、`MusicDiscArtIndex` 走内容判据（假 sampler）且文件名命中优先。
- **备注**：盘面识别仍是进程内缓存、不落库（文件头已述 schema 原因），每次启动首读会按内容重判一次（每个扫图目录逐张降采样解码，第一张中即停）。真机肉眼复测未做（按本机规则不做真机验证），判据的真实数据标定用的是用户本机扫图的 Python 原型（同一套几何与阈值）。
