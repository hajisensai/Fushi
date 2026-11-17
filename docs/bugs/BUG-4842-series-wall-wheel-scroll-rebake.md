## BUG-4842 · 视频系列墙滚轮滚动卡顿：每档滚轮把整屏封面面重新离屏烘焙
- **报告**：2026-11-17（用户：应用内反馈 eBQtk9r7Z2——Windows 3.3.0-debug.26447，3840×2160 @150%，窗口 1336×851 @1.75，约 43 个系列；视频 › 媒体库 › 系列，指针停在网格上连续上下滚轮明显卡顿，每轮最长一次停 0.2～1.1 s，新进视口的封面先黑后出图）
- **真实性**：✅ 真 bug（重烘机制已证实；反馈里的 0.2～1.1 s 停顿在本机没有复现到那个量级，见备注）。两处叠加：
  - `fushi/lib/src/utils/components/baked_surface.dart`（修前 `_endOfFrame` 的 `if (!_textureFits(...)) _unbake()` + `paint` 实时分支的 `_dropBake()`）：面只要离开烘焙时的像素相位就**扔掉纹理**。滚轮一档走根部 `SmoothWheelScrollScope` 的 140 ms 补间，途中全是亚像素位置 → 屏上每个已烘焙的面都把纹理扔了；补间落定后，同一个帧末对整屏所有面逐个 `OffsetLayer.toImageSync` 重烘。合集卡是 glossyPoster 叠层，每张 3 个面。
  - `fushi/lib/src/utils/misc/smooth_wheel_scroll.dart` `_ease`（修前 `target = base + delta`）：落点不对齐物理像素。整体「界面大小」缩放（`FushiAppUiScale`，首启按窗口算出的任意小数，`app_ui_scale.dart` `automaticScaleForViewport`，`normalize` 不取整）叠在 DPR 上，探针实测面的全局缩放是 1.7589 而不是 1.75，一档实际位移 100.5115 物理 px。哪怕纹理不扔，落点和烘焙位置也永远差个零头，像素等价判定（`_Placement.pixelEquivalent`）永不成立 → 照样每档整屏重烘。
- **[x] ① 已修复** — 两处一起改：
  - `baked_surface.dart`：位置离开像素格只 `_hide()` 回实时绘制、**纹理留着**；只有内容真的变了（子树重绘请求）才扔。纹理在、内容没变、又回到与烘焙位置像素等价的地方时 `_reshow()` 直接贴回，不再离屏渲染。
  - `smooth_wheel_scroll.dart`：新增 `snapScrollOffsetToDevicePixels`，补间落点取离 `base + delta` 最近的、乘以「设备像素比 × 祖先变换沿滚动轴的缩放」后是整数的偏移（变换带旋转 / 透视时不对齐）。停稳位置都在同一张物理像素格上，两次停稳之间的位移就是整数像素。每档距离只差不到半个物理像素，不改「系统每次滚动行数决定距离」（BUG-2009）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/widgets/shelf_cover_wheel_scroll_bake_test.dart`：45 张 glossyPoster 合集卡网格，DPR 1.75，真实 `PointerScrollEvent` 走根部补间；整体缩放 1.0 与 1.0051 各跑一遍。断言补间中途实时画、落定后全部贴纹理、每档烘焙次数不超过新滚进视口的面数。修前在 1.0 下就红：「第 0 档：烘焙了 30 次，新滚进来的面只有 0 个」。
  - `fushi/test/utils/components/baked_surface_test.dart`：亚像素途中回到整像素落点贴回原纹理（零次新烘焙、与实时绘制逐像素一致）；途中内容变了就不能贴回旧纹理。
  - `fushi/test/utils/misc/smooth_wheel_scroll_scope_test.dart`：落点对齐物理像素格的单测；「反拨从当前视觉位置起步」的期望放宽到半个物理像素并要求落在格上。
  - `fushi/integration_test/series_wall_scroll_perf_itest.dart`：真 app 探针（profile），复现反馈几何，热轮断言一轮烘焙不超过 4 × 档数。
- **备注**：
  - 真 app 探针（profile 构建、本机 RTX 级 GPU、Windows Impeller、45 个合集、窗口覆盖成 1336×851 逻辑 @1.75、每 250 ms 一档、上下各 40 档）。修前 / 修后同一探针：

    | 轮次 | 修前 烘焙 / 最长停顿 | 修后 烘焙 / 最长停顿 |
    |---|---|---|
    | 冷 | 1178 / 56.5 ms | 63 / 32.6 ms |
    | 热 #0 | 1178 / 22.8 ms | 129 / 30.5 ms |
    | 热 #1 | 1192 / 24.9 ms | 58 / 15.7 ms |

    修前 4 次独立运行的最长停顿为 22.8～89 ms，从没超过 100 ms；反馈里的 0.2～1.1 s 在本机**没有复现到那个量级**——本机 GPU 远强于一般反馈机，`toImageSync` 每次离屏渲染的代价按机器放大。修复去掉的是每档约 15 次整屏离屏渲染这个结构性开销，反馈机上的绝对收益未实测。
  - 本机 Windows Impeller 下 `FrameTiming` 的 raster 段读数恒为 0，拿不到 GPU 耗时，「停顿」只能用相邻两帧 rasterFinish 的间隔量。
  - A/B（同进程短路后重量；关烘焙 / 放大缓存两组只在第 3 次运行里测过，那次还没预置「库页默认改封面网格」一次性弹窗的已处理偏好，弹窗可能在部分时段盖着网格）：关掉烘焙（全部实时画）热轮最长 20～25 ms，对照轮 24～60 ms；图片缓存放大到 2 GB（解码从每轮约 123 次降到 0）停顿没有改善（31.6～34.5 ms）——解码不是主因；把海报 / 截帧都当成比例相合（不走模糊垫底）烘焙数翻 3 倍、停顿升到 60～88 ms（三次运行），反证离屏烘焙就是这里的主要开销。
  - 叠层合集卡后两本里，比例不合槽的截帧走 `PrebakedBlurImage` 模糊垫底，子树里有嵌套 repaint boundary，这些面按设计永不烘焙，帧末每帧都要遍历一次子树确认（探针计到每轮约 5 万次检查）。没改，代价在本机测不出。
  - 「新进视口的封面先黑后出图」：图片缓存上限 100 MB / 1000 张，滚一屏就把前面的解码图挤掉，回滚要重新解码。本机探针里放大缓存对停顿没有可测改善，没动。
