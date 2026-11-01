## BUG-3933 · lyrics-mesh-backdrop-lattice
- **报告**：2026-11-01（用户：iOS / Android 阅读器歌词模式（MD3）背景出现满屏菱形网格，Windows 基本正常；要求 Mac 也看看）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_m3e_player.dart` 的 `_MeshImageCache.resolve` 把整屏 mesh 渐变按**逻辑**尺寸 1/8（`_kMeshDownscale = 8`）画成小图再整屏拉伸：一个纹素 = 8 × DPR 物理像素——iPhone（DPR 3）24 px、Android 高分屏 ~20 px、Mac（DPR 2）16 px、Windows（DPR 1）8 px。8-bit 量化的低频渐变经双线性插值放大后在纹素格上露出分段平面的菱形网格。以前背景常驻流动，网格随相位漂移看不出；10-31 歌词模式改成 `animate: false` 静态（降发热）后网格钉在屏幕上就显形了（不是「首次绘制质量低」，静止期间一直是这张小图）。
- **[x] ① 已修复** — 缓存图分辨率改按物理像素算：静止（不在流动）时按 DPR 全分辨率画一次（只在配色过渡时重画），流动时按 `_kMeshAnimatedTexelPx = 8` 个**物理**像素一纹素降采样；缓存键加入分辨率。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_mesh_backdrop_resolution_test.dart`（DPR 3 下静止缓存图 = 1170×2532 物理像素；流动 = 147×317）。
- **备注**：Apple 风 `LyricsShellAppleBackground` 的模糊快照本来就按物理像素画，不受影响。
