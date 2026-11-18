## BUG-4852 · 开弹幕后视频掉帧：弹幕无 key，队首出列让整屏弹幕文本重录、Impeller 模糊阴影全部重做
- **报告**：2026-11-17（应用内反馈 j2plixDqML，Windows 3.3.0-debug.26447，3840x2160 缩放 150%：「切到全屏后画面不流畅，能感觉到掉帧」「开启弹幕后更明显」；截图为全屏、同屏约 30 条滚动弹幕）
- **真实性**：✅ 真 bug，真 app 探针实测复现（见备注）。根因：
  - **主因——弹幕子项无 key**：`fushi/lib/src/media/video/video_danmaku_overlay.dart:172-188`（修前）每帧按活动集顺序（按出生时间排）生成 `Positioned` 列表、不带 key。队首一出列，后面每个 element 都按位置错配到下一条，`RenderParagraph` 换文本、重新排版、重新 paint——等于每出列一条，整屏弹幕文本全部重录。
  - **为什么重录这么贵**：文字样式带 2 层模糊阴影（`fushi/lib/src/media/video/video_danmaku_text_metrics.dart:39-53`，blurRadius 3）。引擎每次 paint 段落都新建 TextFrame（Flutter 3.47.6 `engine/src/flutter/txt/src/skia/paragraph_skia.cc:98-123`），Impeller 的模糊文字缓存以 TextFrame 指针为键（`impeller/display_list/canvas.cc:2105-2120`、`impeller/entity/contents/text_shadow_cache.cc:43-91`），文本一重录，这条弹幕的阴影缓存就失效、重做离屏模糊。同屏 73 条、每秒出列约 9 条时，几乎每帧都在整屏重做，raster 一帧 190～520 ms，又因为帧长、每帧都撞上出列，形成自我强化。
  - **次因——弹幕层没有自己的重绘边界**：弹幕层每帧 relayout/repaint，会连带同一绘制层里的兄弟节点（视频页上同一个 Stack 里的控制条、遮布、字幕等不在独立边界里的部分）每帧重录。
  - **纠正审查意见**：「每个 vsync 全部弹幕文本都重录」不成立——`Opacity`（`RenderOpacity`，alpha>0 时 `isRepaintBoundary == true`，`packages/flutter/lib/src/rendering/proxy_box.dart:884-887`）本身已把每条弹幕的文本隔成独立图层，平稳滚动的帧里文本不重画（widget 测试的 paint 计数实测为 0）；整批重录发生在队首出列 / 新弹幕入场时。
- **[x] ① 已修复** — 见本分支提交。`VideoDanmakuLayoutEntry` 新增稳定身份 `index`（弹幕在 `items` 里的下标，`video_danmaku_layout.dart` 从 `_ActiveItem.index` 填）；overlay 改为 `IgnorePointer > RepaintBoundary(整层) > AnimatedBuilder > LayoutBuilder > Stack[Positioned(key: ValueKey(index)) > Opacity > RepaintBoundary > _DanmakuText]`：位置与透明度留在每条的边界外、每帧只改图层偏移；文本 picture 从出生到退场原样复用，Impeller 阴影缓存命中。同一条弹幕复用同一个文本子树 widget 实例（换弹幕列表 / 字号 / 关弹幕时整体作废），element 直接跳过重建。字号、阴影、透明度、滚动轨迹、行分配都没动，不节流、不降帧率。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_danmaku_overlay_repaint_test.dart`（`debugProfilePaintsEnabled` + `FlutterTimeline` 数 `RenderParagraph` 真实 paint 次数）：① 弹幕滚动的帧里弹幕文本与同层兄弟文本都不重新 paint；② 队首出列后其余弹幕仍由原来那个 `RenderParagraph` 渲染、paint 次数为 0。修前代码上两条都红。真 app 帧时探针 `fushi/integration_test/video_danmaku_raster_perf_itest.dart`。
- **备注**：实测（Windows 离屏 runner，**debug 构建**，物理 2864x1766、DPR 2.0、显示器 144 Hz、帧预算 6.94 ms；1080p mpeg4 素材边播边量，每窗口 10 秒；sidecar 弹幕前 30 秒约 3.5 条/秒、后 30 秒约 9 条/秒，文本各不相同）：

  | 窗口 | 屏上条数 | 帧数/10s 修前→修后 | raster p50/p95/max ms 修前 | 修后 | build p50/p95 ms 修前 | 修后 | raster 超预算帧 修前→修后 |
  |---|---|---|---|---|---|---|---|
  | 弹幕关 #1 | 0 | 1046 → 1347 | 1.3/2.6/68.0 | 0.8/1.4/5.8 | 0.4/2.1 | 0.3/0.5 | 4 → 0 |
  | 弹幕开 低密度 | 27 | 830 → 1275 | 3.1/14.7/156.7 | 2.3/4.5/26.9 | 2.3/10.9 | 1.6/3.0 | 93 → 11 |
  | 弹幕开 高密度 | 73 / 71 | **56 → 1202** | **191.2/464.3/525.4** | 4.4/7.8/13.5 | 16.8/72.3 | 2.1/4.5 | 56 → 121（修后 1202 帧里约 10% 超 144 Hz 的 6.94 ms 预算，最长 13.5 ms；修前是所有帧都远超） |
  | 弹幕关 #2 | 0 | 1318 → 1295 | 1.1/2.1/10.5 | 1.0/1.9/64.3 | 0.2/0.6 | 0.2/0.4 | 1 → 15 |

  修前高密度一档 10 秒只出 56 帧（约 5.6 fps）。debug 构建的 build 时间偏大，只看相对变化；raster 在引擎侧，与 profile 量级接近但未在 profile 下复核。弹幕关的两窗口前后差异（max 偶发尖峰）是噪声量级，与本改动无关。
  观感：暂停在 45 秒同一画面（72 条弹幕）按 DPR 抓真像素，修前修后 5728x3532 逐像素 diff 为 0。滚动中（阴影缓存命中、按新的亚像素偏移重采样缓存纹理）的帧没有逐帧像素对照。
  全屏没量：离屏 runner 进全屏会盖住使用者整块显示器；弹幕层的开销随屏上条数与 DPR 走，与是否全屏无关。用户 3840x2160@150% 全屏的逻辑尺寸比探针窗口更宽，同屏条数更多，修前只会更差。
