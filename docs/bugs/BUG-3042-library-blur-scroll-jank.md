## BUG-3042 · 游戏库/视频库滚动掉帧：卡片封面背景渲染期实时模糊
- **报告**：2026-10-05（用户：协作者 shishamo Windows 录屏 `2026-10-05 16-18-26.mp4`，「这个滚动掉帧」）
- **真实性**：✅ 真 bug（#1971 之后）。根因 `fushi/lib/src/pages/implementations/games_library_page.dart:2347-2361`（「继续游戏」卡 key art 背景 `ImageFiltered(blur 22)`），同类 `fushi/lib/src/media/video/cover_ui/portrait_cover_image.dart:120` / `landscape_cover_image.dart:157`（封面比例不符时的模糊垫底，sigma 14 / 28）、`fushi/lib/src/pages/implementations/galgame_home_page.dart:676`（游戏首页大卡，sigma 28）
- **[x] ① 已修复** — 03a10a950ea：新组件 `PrebakedBlurImage`（`fushi/lib/src/utils/components/prebaked_blur_image.dart`）把封面按 fit 铺进按 sigma 降采样的小画布、`Picture.toImage` 只模糊一次，之后每帧只画一张纹理；四处调用点换用它
- **[x] ② 已加自动化测试** — `fushi/test/widgets/prebaked_blur_image_test.dart`（与原 ImageFiltered / ImageFiltered+ColorFiltered 像素对比 mean ≤0.65/255、max ≤5；源码守卫四个文件不得再出现 `ImageFiltered(`）；层序/朝向守卫改认 `PrebakedBlurImage`
- **备注**：帧耗时探针 `fushi/integration_test/library_scroll_perf_itest.dart`（本机 profile gen_snapshot 栈溢出，只能 debug 离屏 runner 看 raster 段）

### 录屏量化（ffmpeg 逐帧差分，60 fps 录屏）

| 页面 | 运动帧 | 重复帧 | 有效 fps |
|---|---|---|---|
| 查词历史 | 4 | 0 | 60 |
| 游戏库（第一段） | 21 | 13 | 22.9 |
| 视频库 | 54 | 5 | 54.4 |
| 书架 | 105 | 15 | 51.4 |
| 游戏库（第二段） | 33 | 20 | 23.6 |
| 设置 | 7 | 0 | 60 |

只有游戏库掉到 ~23 fps；画面里就是两张带模糊 key art 的「继续游戏」卡。

### 根因

`ImageFiltered` 是渲染期滤镜：每帧对整块子树重做高斯卷积。Skia 静止时有 raster
cache 兜，但滚动 / 悬停抬升（矩阵变化）时缓存失效；Impeller 没有 raster cache。
库网格里每张卡一份，滚动代价随可见卡数线性增长。

### 修复

模糊只在「图 / 输出尺寸 / 参数」变化时算一次：画布每 sigma 留 6 px（模糊后无高频，
双线性拉回看不出差别），saveLayer + blur 与原 ImageFiltered 同一种边缘行为；封面
垫底的 srcATop 压暗作为 `colorFilter` 一起烘进去。墨水屏路径不模糊不变。

### 帧耗时（debug 离屏 runner，4K@144Hz，raster 段，r1 轮）

| 页面 | 修前 raster p50/p90/p99 ms | 修后 | 超预算帧 修前 → 修后 |
|---|---|---|---|
| 游戏库 | 1.01–1.22 / 1.49–1.93 / 6.7–9.4 | 0.61 / 0.94 / 1.53 | 17–18% → 8.5% |
| 视频库 | 1.43–2.04 / 3.2–7.7 / 20.7–21.1 | 1.04 / 1.91 / 3.83 | 23–50% → 11% |

本机多 agent 并发，绝对值有噪声，修前跑了两次给区间。
