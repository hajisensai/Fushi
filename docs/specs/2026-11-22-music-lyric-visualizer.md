# 音乐歌词页：全屏歌词动画（移植 folia-major 的歌词动画样式）

- 日期：2026-11-22。所有者拍板：照 [folia-major](https://github.com/chthollyphile/folia-major)（commit `a772a97`）的
  全屏歌词动画做，**18 套样式全做**；全屏动画里**纯观赏、不点词查词**，点一下 / Esc / 返回键退出回原布局；
  **镜台（Diorama）用 flutter_gpu 做真 3D**（「大不了 fork」），拿不到 GPU 上下文的平台退回 CPU 版。
- 许可：folia 是 AGPL-3.0，本仓是 GPL-3.0。各样式是读懂 folia 算法后用 Dart 重写的移植（衍生作品），
  folia 的图片（头像 / 表情 / 纹理）与字体一律没有搬进来，用封面与程序绘制代替。

## 结构

| 位置 | 作用 |
|---|---|
| `fushi/lib/src/media/music/lyrics/visualizer/lyric_visualizer.dart` | 契约：`LyricVisualizerMode`（落库值 = folia 模式 id，冻结）、`LyricVisualizerContext`、配色、最小时钟接口、可调参数声明（滑杆 / 开关 / 单选）、注册项 |
| `.../lyric_visualizer_runtime.dart` | 共享运行时：当前行 / 间奏 / 上一句 / 下一句、逐字与逐词时间线（行级歌词按行均分）、`pulseAt` 歌词节拍包络、种子随机 |
| `.../lyric_visualizer_frame.dart` | 唯一的逐帧驱动（Ticker → `LyricVisualizerTicks`，画家 `repaint: ticks`） |
| `.../lyric_visualizer_subtitle.dart` | 共享底部字幕（译文 + 下一句） |
| `.../lyric_visualizer_registry.dart` | 样式 → 注册项；守卫测试核对与枚举一一对应 |
| `.../modes/<样式>/` | 各样式实现（每个样式一个目录，测试在 `fushi/test/media/music/visualizer/modes/`） |
| `fushi/lib/src/pages/implementations/music/music_lyric_visualizer_view.dart` | 宿主：背景之上画样式、共享字幕、悬停条（换样式 / 退出）、选择面板、通用参数面板 |
| 歌词页 `music_lyrics_page.dart` | 工具栏「歌词动画」→ 选择面板 → 页内全屏层；返回键先退出动画 |
| 设置 › 音乐 | 样式、每首随机、字号；各样式参数在选择面板的齿轮里调 |

偏好键：`music_visualizer_mode` / `music_visualizer_random` / `music_visualizer_font_scale` /
`music_visualizer_tunings`（JSON，只存改过的项）。

## 共性缺口（待补，登记于此）

1. **实时音频分析**：Fushi 没有实时频谱 / 节拍检测（folia 有 `audioPower` / `audioBands` 和「智能动感模式」
   beat FX，含 beat_this / htdemucs 模型）。现由 `runtime.pulseAt`（歌词起字包络）代替，各样式的随拍效果都是
   「跟唱词」而不是「跟鼓点」。补法：音频引擎侧出低成本的 RMS / 频段流（Rust 胖核心，一条事件流），各样式
   换接；节拍检测模型另议。
2. **副歌 / 段落标记**：`LyricLine` 没有 `isChorus` / `songPart`。云阶、流光、回环、时计、花火、町景、隐喻
   等依赖副歌的效果要么缺、要么各自用「重复句」启发式。补法：在 runtime 统一提供副歌判据（来源格式带标记时用
   标记，否则共享启发式），删掉各样式里的本地实现。
3. **render hints**（folia `renderHints.ts`：micro / short / normal 行分级、`renderEndTime` 句尾离场窗口）：
   流光、云阶、心象、群唱各自本地移植了一份。补法：收进 `LyricVisualizerRuntime`。
4. **词级分词**（folia `Intl.Segmenter` + AI 分词）：runtime 把每个 CJK 字当一个词，商籁 / 雾笺 / 花火等
   自己做了近似分组。补法：框架提供共享分词结果。
5. **主题强度 / 按词着色**（folia AI 主题的 `animationIntensity`、`wordColors`）：没有对应数据；强度在
   群唱 / 云阶 / 流光 / 心象里各成一个「动画强度」参数（键名重复）。补法：上收为共享参数。
6. **参数类型**：缺文本输入、颜色、预设、条件显隐、嵌套（町景的多视角）。
7. **背景独立组合**：folia 的背景可以和任意样式组合（如莫奈背景配别的样式）；这里背景是样式的一部分
   （`sharedBackdrop` 只是开关，且不能按参数计算，雾笺在街景 / 水族箱下多画了一层宿主背景）。
8. **封面加载工具**：群唱 / 凝彩直接用了页面层的 `musicLyricsBackdropCoverProvider`，时计只读本地封面。
   补法：挪到框架层共享。
9. folia 的用户上传素材（群唱头像包 / 表情包、凝彩画布图层、莫奈人像）、OBS / mod / 预览模式不移植。

## 各样式与 folia 的差异（移植代理逐条报告）


### 流光（luminous）

- Chorus ripple (the expanding ring on active words in isChorus lines) is not drawn: Fushi's LyricLine / runtime has no chorus flag.
- Per-word colouring (theme.wordColors via resolveWordColor) is not ported: Fushi has no word-colour table, so every active word uses palette.accent and the base colour is palette.text.
- Folia's animationIntensity is a global theme setting; here it is a per-style choice tuning 'animationIntensity' (calm/normal/chaotic, default normal).
- useLegacyLayout is stored as the choice tuning 'layoutMode' (adaptive/legacy) instead of a boolean; defaults and the other tuning keys and ranges match folia (enableWordRotation, breathingFloatMultiplier 0-2 default 1, wordSpacing 0-2 default 0.7, avoidOverlap).
- Adaptive layout only does the sticky-punctuation / direct-contraction merge. Folia's Intl.Segmenter CJK semantic grouping is not ported; for classic it only influences wrap units, since semantic units still render per character.
- framer-motion's default transitions for the line enter are approximated (opacity/blur 0.3 s ease-out tween, scale critically-damped spring k=100). Word layout, body and glow variants follow folia's exact durations and keyframes.
- chaotic alignSelf (flex-start/flex-end) and the container perspective are dropped: all word boxes have the same height and nothing uses 3D, so they have no visible effect.
- Text glow uses TextStyle.shadows on a transparent glyph (folia's text-shadow path) with the CSS radius converted to a Flutter blurRadius; the Linux drop-shadow variant is not needed.
- Addition over folia: a single unbreakable word wider than the container is scaled down (floor 0.3) so long Latin words don't run off narrow screens.
- Seeking or scrubbing jumps straight to the time-derived state (no animation from the previous frame), because every animation is a pure function of lyric time. During forward playback this matches folia's motion.
- No audio reactivity is lost: classic does not read audioPower; shared backdrop and shared subtitle (translation / next line) stay with the host, as in folia's VisualizerShell / VisualizerSubtitleOverlay.

### 心象（mindscape）

- folia 用 audioPower 驱动的整体上下浮动（verticalLift）和每个词的漂浮（localFloat），这里改由 runtime.pulseAt(t) 的起字包络乘 motionAmount 驱动，不是实时频谱。
- tuning 里的 beamIntensity（folia 自己已经恒为 0）和 render（画布分辨率覆盖）没有移植，Flutter 按设备像素比绘制，这两项没有意义。
- folia 的 theme.animationIntensity（calm/normal/chaotic）在 Fushi 没有对应的主题属性，改成本样式的单选参数 animationIntensity，默认 normal。
- theme.wordColors 关键词着色在 Fushi 没有对应数据，所有词的高亮色统一用 palette.accent，底色用 palette.text。
- 副歌判定：folia 的 isChorus 来自歌词源提供的 chorus 区间或 detectChorusLines；这里只在本地移植了「重复次数最多的歌词文本算副歌」这一条启发式，不读歌词源的 chorus 时间区间。
- 文字测量和换行由 pretext 换成自写的贪心换行，每个单位用 TextPainter 量宽，字形步进按比例分摊。断行规则不完全等同于 pretext（例如避头只是一张简单的标点表）。
- 三层 40px text-shadow 合成为一层同半径的阴影，透明度按 over 叠加，再用 saveLayer 的透明度控制强弱。效果相近，不逐层一致。
- folia 的 lineLayer perspective 对 2D 旋转没有作用，chaotic 下随机透视距离这一项没有移植。
- folia 的 waitingForMusic 文案本来就是空串，没有画间奏占位文字。
- 减弱动态效果时，未唱的词按 0.35 透明度静止显示（folia 原本是隐身），这样一帧静止画面能看到整句。这是按任务规格的取舍。
- zh-TW / zh-HK 两个 json 里这批新 key 的值是英文（i18n_sync --add 只给 en/zh-CN 写值），需要协调方决定要不要补繁体。

### 浮名（fume）

- Audio reactivity: Fushi has no spectrum, so spark size and opacity follow runtime.pulseAt() mapped onto fixed band weights (treble 1, vocal 0.9, mid 0.75, lowMid 0.6) instead of real audioBands.
- Dropped tuning disableGeometricBackground: it only toggles the geometric shapes of folia's shared shell backdrop, and the Fushi host backdrop has none. FumeBackground's own shapes are always drawn and are controlled by backgroundObjectOpacity, as in folia. The render-quality override and mod hooks are dropped too.
- Fushi lyrics carry no chorus flag, so folia's 'isChorus -> hero' and chorus score in hero selection are dropped. Heroes come from the every-6th-line / seeded-random / fallback rules only.
- Per-word colours (theme.wordColors via resolveWordColor) are not available: active glyphs always use palette.accent. The folia theme is mapped as primaryColor -> palette.text, secondaryColor -> palette.secondary, accentColor -> palette.accent.
- animationIntensity is fixed at folia's 'normal' constants (glow 0.92/0.62, float 18px/7s), because Fushi themes have no calm/chaotic intensity.
- Text measuring: folia uses @chenglou/pretext. Here the font-size fit uses one TextPainter natural-width measurement at 100px, scaled linearly, and wrapping and glyph offsets come from TextPainter. The default app font is used, with weights w800 (hero) / w600 (body) instead of folia's 780/640.
- Layout runs synchronously when the scene is first built, not in time slices. folia's 'laying out' hourglass card is therefore not ported, and a very long song may cost one slow first frame.
- The passed-text cross-fade (standard -> dimmed) is drawn as one interpolated style, quantized to 1/32, instead of two blended snapshot layers. Glyph shapes are identical, so the look is equivalent.
- Canvas 2D shadowBlur is in screen pixels. Live glyph glow and stamp blur are divided by the camera scale to match. Static passed-block glow stays in world units, like folia's scaled snapshots.
- folia's Linux glyph-cache workaround (FumeLiveRaster) and the first-frame transition signal are not ported; they are Chromium-specific.
- The scale-in from 0.985 to 1 when printing starts is an exponential approach of about 0.45s, not framer-motion's easeOut tween.

### 云阶（partita）

- CJK semantic layout: folia uses Intl.Segmenter / AI word segmentation (with the user's saved split). Here a script heuristic groups runs of adjacent single-character CJK runtime words: a Hangul run or a Katakana run is one unit; Han characters go in pairs, with a leftover one joining the last pair; 1–2 hiragana directly after Han/Katakana join that unit; other hiragana go in groups of up to 3. Word boundaries can therefore differ from a real dictionary segmentation.
- Parser words are replaced by Fushi runtime words: CJK one per character, Latin split on spaces, so 'It's' is already one word. Sticky-punctuation rules are ported unchanged and mostly fire for full-width CJK punctuation and space-separated commas or contractions.
- Animation intensity came from folia's AI/cover theme (theme.animationIntensity). Here it is an extra choice tuning 'intensity' (calm/normal/chaotic, default normal). With motion off it is forced to calm.
- Per-word colours (theme.wordColors / resolveWordColor) are dropped. The active colour is always palette.accent and the base colour palette.text.
- Chorus ripple (isChorus) is not drawn: Fushi's LyricLine has no chorus flag.
- folia's audioPower/audioBands only feed VisualizerShell's backdrop. Partita itself is not audio-reactive and the backdrop is the host's shared fluid backdrop, so pulseAt is not used.
- framer-motion behaviour is approximated with closed-form functions: springs (stiffness/damping 200/20 for words and rows, 500/25 as the default for line scale), with unspecified transitions assumed to be framer's default easeInOut tween. An interrupted transition restarts from the pose computed at the state-switch time, not from live velocity.
- Glow is drawn as Flutter text Shadows on transparent text (CSS radius r converted to Flutter blurRadius via sigma = r/2), with alpha quantised to 1/32 steps. folia's Linux drop-shadow fallback is not needed.
- The 'fit to area' shrink always applies (min 0.3) so long or narrow layouts stay on screen. folia only shrinks when avoidOverlap is on and otherwise lets nowrap rows overflow.
- The avoidOverlap spacing is computed in px from measured TextPainter widths, not with folia's em+px CSS calc. The algorithm is the same: pair reaches, row reaches and turn estimate.
- folia's 'Waiting for music' empty-state text is an empty string in its locales, so nothing is drawn between lines, same as folia.
- Mod hooks (modKeys/modPatch), quick-control chip and command-palette entry are dropped. A swapped staggerMin/staggerMax is reordered when read, not when the slider moves.

### 群唱（cappella）

- folia 的内置头像 PNG 没有搬过来，换成按调色板生成的圆形头像：渐变底 + 人像剪影；演唱者有名字时显示首字母。设置里的选项值仍是 'builtin'，界面上叫「生成头像」。
- folia 的「自定义」头像来源和用户上传头像 / 表情包的功能（IndexedDB 存储的头像包、表情包，以及 emojiPackSource 参数）没有移植。
- 表情 PNG 换成 8 种程序绘制的表情脸贴纸（微笑 / 大笑 / 眨眼 / 惊讶 / 心心眼 / 落泪 / 墨镜 / 唱歌加音符），白描边，脸色从调色板取；每条消息选哪一种仍用 folia 的种子算法。
- 封面头像来源下，没有封面或封面还没加载完时，用生成头像代替（folia 是退到内置图）。
- folia 的动画强度来自 AI 主题的 animationIntensity，Fushi 没有这个概念，改成本样式的「动画强度」参数（平静 / 标准 / 混乱，默认标准）。
- 主题色对应关系：folia 的 primaryColor（前景字色）对应 palette.text，accentColor 对应 palette.primary，secondaryColor 对应 palette.secondary。另外加了一条 folia 没有的规则：气泡字色和底色对比度低于 3:1 时，字色换成另一端（背景色或前景色），因为封面取色不保证对比度。
- framer-motion 的 layout="position" 换位动画用指数平滑近似（时间常数 0.09s），不是逐帧还原 framer 的布局补间。
- 从激活切回普通状态时，字号和内边距瞬时切换、气泡框 0.2s 补间，这和 folia 一致；字在框补间期间被裁剪。
- 减弱动态效果时，当前句整句直接显示，没有逐字淡入；folia 没有这个模式。
- folia 的字体和字重主题（resolveThemeFontStack / Weight）没有接，用 App 默认字体、字重 400。
- folia 的 cappella 本身不读 audioPower / 节拍，所以没有需要用 pulseAt 代替的音频响应部分。
- 预览模式下强制插入表情（isPreviewMode / forcePreviewEmo）没有移植，Fushi 的宿主没有这个模式。

### 回环（claddagh）

- Fushi 没有实时频谱：folia 平滑后的低音 / 人声能量（环半径鼓起、中轴线变色伸缩）改用 runtime.pulseAt（衰减 320ms）加一段 70ms 起音的闭式包络代替，峰值约 0.56；暂停或关闭动效时为 0。
- Fushi 的歌词数据没有副歌（isChorus）标记，folia 副歌专属效果全部画不出来：奇偶字上下错位、三层副歌发光、中轴线副歌光晕。
- theme.wordColors（按词着色）在 Fushi 没有对应数据，已唱的字统一用 palette.accent。
- theme.animationIntensity 固定按 folia 的 normal 档（倍率 0.25，上限 1.25），calm / chaotic 两档没有设置项。
- 字号：folia 固定 72px×字号倍数；这里画布不到 1100 宽时再按宽度缩小（最小一半），中轴线长度同比缩，好让 390 宽的手机放得下。
- 主题字体和副字幕字体都换成应用默认字体，歌词 w700、译文 w600。
- 环切换弹簧的时钟用歌词显示时间，不用墙钟：暂停时停在半路，向后拖进度直接到位。
- folia 的「播放重置时冻结一帧」（shouldHoldCladdaghFrameForPlaybackReset）是为 React 提交滞后打的补丁，这里没有这个问题，不移植。
- 关闭动效时：环不跟唱词转，当前行居中静止，后面的行停在背面；不做闪光冲高和能量脉动，逐字变色照常。
- 整体透明度（CSS opacity）分别乘进字色和发光色的 alpha，不对整个字做合成；发光与字形重叠处和 CSS 会有细微差别。
- 为了缓存，颜色 alpha 按 1/64、模糊按 0.25px、发光半径按 0.5px 量化。
- 共享背景和底部共享字幕沿用宿主的（sharedBackdrop / sharedSubtitle 都为 true），与 folia 用 VisualizerShell 加字幕浮层一致。
- 没有用 shader，全部走 CPU 绘制，没有照搬任何 folia 素材。

### 莫奈（monet）

- 频谱与音频脉动：Fushi 没有实时频谱。folia 读 audioBands / audioPower 的地方，改用 runtime.pulseAt(t)（唱词起字包络）合成五段频带（monetSyntheticBands），所以频谱跟着唱词冲高回落，不跟真实音乐走。
- 关键字着色（keywordColoringEnabled）已去掉：它依赖 folia AI 主题的 wordColors，Fushi 没有对应数据，所有计时词都用主色@0.98。
- 副歌光晕（isChorus 的椭圆强调色光晕，以及副歌行扫字色混入强调色）没有实现：Fushi 的 LyricLine 没有 chorus 标记。
- 浮动装饰（MonetFloatingDecor）没有实现：folia 只画主题自带的 lyricsIcons，主题没有图标时本来就不画；Fushi 主题没有图标，所以没有装饰。
- 封面在 chaotic 强度下的晃动动画没有实现：Fushi 没有 theme.animationIntensity。
- 描述胶囊的文字原本是 AI 主题描述（theme.description / name）或用户自定义文本，这里统一显示样式名「莫奈 / MONET」（folia 的最终兜底值）；customDescription 无法用现有参数规格表达（框架没有文本输入），已去掉。
- 肖像拖拽（拖动挂钩按钮、方向键微调、虚线编辑框）和 portraitHangerVisibility 已去掉：可视化页内不处理交互；portraitOffsetX 改成 -150..0 的滑杆，键名和语义与 folia 一致。
- 肖像来源去掉了 custom（用户上传立绘），背景来源去掉了 uploaded-global（上传背景图），水洗色去掉了 custom 及自定义色（框架没有取色器）：一律用封面和主题色。
- 分辨率覆盖（render）、歌词栏的滚轮 / 触摸手动滚动、点击行跳转、混音交接（songHandoff）都已去掉：前三项是交互或渲染档位，交接是 Fushi 没有的宿主能力。换歌时只重播海报入场，肖像用 900ms 交叉淡入。
- 译文只显示一轨：优先显示 translation，没有译文时显示 romanization。folia 的「罗马音 + 译文」双轨（subtitleContentMode='both'）来自全局设置，这里没有接。
- RTL 歌词（阿拉伯文、维吾尔文）的扫字方向没有特殊处理，始终从左往右扫；镜像布局时整体右对齐。
- 描述胶囊的 backdrop-blur 磨砂效果没有画：每帧做 BackdropFilter 太贵，只保留半透明底色和描边。
- 背景烘焙在 1280×720（folia 是 1920×1080），模糊半径按比例缩小；封面解码时长边上限 960px。
- 字体使用应用默认字体；folia 的主题字体栈和字重设置没有接（统一用 w600，译文 w500）。
- 测试里没有封面，所以封面解码、isolate 逐像素处理、烘焙和肖像加载这条路径在 flutter test 中没有执行；逐像素处理、水洗映射和漂移的纯函数单独做了单测，烘焙结果没有在真机上看过。

### 镜台（diorama）

- 没有真实音频分析：涟漪、脉冲、持续音由歌词时间代替，节拍特效（歌词跳动、节拍涟漪、Mirror Ripples）没有移植。
- 关键词着色没有移植（时间线里没有 wordColors）；folia 的渲染质量覆盖选项也去掉了。
- folia 跟随主题的 animationIntensity 换成了本模式自己的 cameraStyle 调参（平静 / 普通 / 激烈）。
- 2.5D 的近似：文字平面用局部仿射代替真透视，没有深度缓冲和排序（点云总画在文字下面），雾化用透明度渐隐模拟。
- CPU 点云只用 folia 点数的一半（dioramaCpuPointShare=0.5）；颜色对比度调整简化为最低对比度 3。
- 没带 folia 的自定义字体；整行放不下时会折行（folia 不折行，而是缩放）。
- 没有 folia 的「等待音乐」占位和就绪门；纯音乐用 96 条每条 5 秒的空行走镜头。
- i18n json 与 strings.g.dart 已经由加锁脚本写入，但按规范没提交，由委托方汇总。
- 没在真机或模拟器上看过实际帧率和画面效果，只跑了单元测试和挂载冒烟测试。

### 时计（pendolo）

- Audio: folia's balance wheel speed and swing follow realtime bass. Here they follow runtime.pulseAt(t)*0.6, the lyric-onset envelope, through the same 0.12 smoothing.
- Beat effects dropped: drumhead halo, shockwave lens, sparks, screen shake, jewel flares and gear-on-beat. Folia retired the beat-list effects anyway, and the drumhead effect needs HTDemucs drum stems.
- Theme animationIntensity (calm/normal/chaotic motion profiles) does not exist in Fushi, so the 'normal' profile is fixed (every multiplier = 1).
- Chorus emphasis dropped: halo, glow, accent mix 0.58 and the chorus marker during manual scroll. Fushi's LyricLine has no isChorus. Fill uses the non-chorus accent mix of 0.32.
- Per-word colours (theme.wordColors) are not supported. The fill is one colour, mix(text, primary, 0.32).
- Interaction dropped by design (display-only visualizer): wheel/touch manual scrolling of the arc and tap-to-seek on a line.
- Balance icon: folia draws the theme's lucide icon (Star fallback). Here it is always a procedural outline 5-point star.
- Cover on the watch face: loaded from local coverPath with FileImage, resized to 512 px and centre-cropped square. folia stretches the image. http cover URLs are not loaded.
- Hub view: lines stand upright, facing the screen at their projected anchor, scaled by perspective depth. This replaces folia's DOM rotateX/preserve-3d. Parts behind the camera are clipped with a half-plane in plane space. There is no depth-buffer occlusion between layers; parts are drawn in order of height.
- Tilt/parallax: folia hides the clockwork behind the lyric layer using depth/stencil. Here layers are painted in height order with no occlusion.
- Line glow: a blurred, tinted copy of the recorded clockwork Picture (sigma 6 at 0.3 and sigma 2 at 0.65) stands in for the CSS drop-shadow 4px/12px.
- Dropped tuning: render (resolution/antialias override), which is meaningless here. folia's presets 1-3 are not exposed because the framework has no preset buttons. Every individual tuning is declared with folia's defaults and ranges (wheelCenterX uses tuning.ts's -0.3..0.5).
- Subtitle row: translation, or romanization when there is no translation. folia's 'both' mode, which stacks two rows, and its separate subtitle font scale are not ported; the lyric fontScale is used.
- Rotation pivot: each line's text rotation and scale pivot on the arc anchor. In folia the pivot is the box's left-center before the -50% shift, which differs by half a block height.
- No-lyrics mode: the wheel steps every 5 s right away, without folia's 3 s READY_GRACE wait for instrumental detection.
- Non-focal to focal font size change is instant. folia has a 200 ms CSS transition on the non-focal div.

### 商籁（sonnet）

- folia 的 100 种几何主图只移植了 0–17，变体号按 % 18 回落；18–99 是主题插画类，没有移植。
- 节拍特效（镜头撕裂、缩放冲击）没做。图标随音乐放大改用歌词节拍 runtime.pulseAt，不是 folia 的音频能量。
- folia 的 Lucide 主题图标换成了程序画的五瓣描边花；没有复制 folia 的素材和字体。
- folia 的主题名 / 描述（AI 主题）换成了曲名、艺人、专辑。
- CJK 分词是启发式规则，没有 Intl.Segmenter；Fushi 也没有副歌 / 段落结构的元数据，所以副歌相关分类没有生效。
- textureResolution 和渲染覆盖类参数没移植。
- 着色器加载失败时，CPU 回退只有 RGB 错位和暗角，没有镜头扭曲、色散和网点。
- 故障条转场只做了 14 条粗带（重画画面并平移，58 条细带合并成带内的次级偏移）；胶片颗粒用随机点近似。
- 导引线和圆的起笔用种子随机，不用 Math.random，所以每次播放都一样。
- 镜头之间空档时的漂移（gap drift）没做，深度视差也比 folia 简化了。
- 移植只靠单元测试和 widget 冒烟测试验证，没有在真机或模拟器上看过画面效果。

### 凝彩（tempera）

- Audio: folia tempera's only audio-driven effect is the drum-triggered ink flash. It is not ported, and runtime.pulseAt is not used.
- User-uploaded image layers are out of scope. The image layer pool contains only the cover, with alignment fixed to free horizontally and bottom vertically. Layer scale and opacity are exposed as sliders.
- Text inversion is emulated on the CPU, not as folia's per-pixel shader. Text is recoloured to ink or paper for each block shape of the same shot, using the block's alpha-mixed colour (alpha below 0.34 is ignored). The ground counts as paper. Blocks from a shot that is handing off, the cover image and the host backdrop showing through holes do not affect the decision. The 5-tap smoothing is not reproduced.
- Post-processing: lens distortion, RGB shift and texture compression or resolution are not ported. Grain is seeded per-frame points; vignette and contrast are a radial gradient and a colour matrix inside the scene layer.
- The depth toggle switches instantly instead of easing in over time. Depth blur uses ImageFilter.blur at draw time instead of being baked into textures.
- No word segmenter is available, so word splitting uses a heuristic: Latin runs, Hangul runs, Han or katakana plus trailing hiragana, and Chinese Han split into pairs.
- Fushi has no song-part metadata, so paragraph kinds chorus and break and metadata-driven paragraph boundaries never occur. Paragraphs split on gaps and line count only.
- The theme wordColors keyword layer is not available, so the keyword colour layer is never filled.
- The animationIntensity theme multiplier (calm / chaotic) is not mapped; the camera and glyph-motion sliders cover it.
- Fonts: the default theme family is used at weight 600, with TextPainter measuring instead of pretext. Glyph TextPainters are cached with alpha quantised to 1/32.
- A cross-session song-swap handoff and a one-task-per-frame scene preloading scheduler are not ported. The scene cache builds lazily and keeps the active paragraph plus or minus one.

### 绘光（lumiere）

- 没有真实音频分析：音乐驱动只用 runtime.pulseAt 的歌词起音包络代替 folia 的 bass/power。
- Fushi 的 LyricLine 没有 songPart/isChorus/blockIndex，不会判成 chorus（副歌）段，也不能按元数据分段，只能按时间间隔分段。
- 没用片元着色器：光场在 CPU 上按网格顶点算再插值，窄光丝、焦散细纹和干涉条纹比 folia 的逐像素渲染软；全画质下每帧约 3000 个网格顶点加每束光最多约 1800 个顶点，低端机建议选均衡或省电，没在真机上测帧率。
- 图形辉光与文字辉光是近似做法（加宽描边、光点光晕、眩光放大），没有 folia 的全屏模糊 bloom 后处理。
- 背景歌词碎片用实心字低透明度画，不是 folia 的空心描边字。
- 竖排只在当前行以 CJK 为主时启用，拉丁文行退回横排（folia 会转写）。纵横（crossed）排版的自由落点简化成当前行两侧的固定槽位，没有完整移植 lineClearance / windowProtection 的避让计算。
- folia 原文里 prismTriangle 线稿的函数体被截断，按名称和调用参数重建。
- 去掉的调节项：渲染倍率与抗锯齿覆盖、keywordColors、themeIcons（Fushi 主题没有 wordColors/lyricsIcons）；不带 folia 的自定义字体，用应用默认字体。
- folia 用 pretext 量字，这里改用 TextPainter 的字宽；切块、错峰等时间常数照搬，但 STACK_GAP 等槽位间距按字号重新标定，不是逐像素复刻。
- 没在真机上看过实际画面，只有 widget 冒烟测试（默认、非默认组合、仅文字、行级歌词、关动态、390x844 竖屏）。

### 雾笺（nebbia）

- 音频联动：folia 的人声包络（audioBands.vocal / HTDemucs 人声轨）在这里换成 runtime.pulseAt(decayMs 400)：小雨点按每 20 ms 一格的泊松速率落，大雨点在 60% 的词开唱处砸（folia 没分析音轨时的退路），没有真实起音和整首响度倍数。
- 智能动感模式的两项没移植：「疏雨轻车」的鼓点颠簸和「舞潮踏拍」跟拍时水母收缩、水草摆动、冒排泡、光斑放大。颠簸一律按种子随机（平均 7.5 秒一下）。
- 没有 AnimCJK 笔顺数据（APL 授权，folia 也不入库）：中日文和拉丁字一样走字体骨架追踪，笔顺按从上到下、从左到右估。骨架是异步生成的，好之前（以及测试里）用扫笔字形：字形是真的，笔画顺序是几道横扫；扫笔字形的擦痕边上不挂小水珠，只有收笔水珠和下淌水珠。
- complexScale（10 笔以上的字放大）依赖笔顺数据，没有实现，所有字都按 1 倍。
- 分词用的是本地近似算法：中文汉字两字一词、虚词单独成词；日文按「汉字 + 送假名」和片假名串切、格助词断开；拉丁按空格切。folia 走的是 Intl.Segmenter 或用户保存的分词，所以主词选择可能和 folia 不同。
- 图标和 emoji 不复制 lucide 资源，改成自己画的 10 种线稿（心、星、月、太阳、音符、花、闪光、伞、笑脸、叶子）。folia 用主题的 lyricsIcons，这里固定只用这一组。
- 折射是近似的：水珠画成比雾暗的身子、底部一弯折上来的灯光、左上一点高光，不是真正去采样折射的窗外。雾的浓淡噪声改成几团大软斑慢慢飘；擦痕的毛边改成 MaskFilter 模糊，没有用噪声阈值。
- 颠簸后的弹簧甩动和甩出的印子（smears）没有移植，只保留整体位移、水珠细颤、大水珠震落和水痕。被震落的水珠淌完、回雾后回到原处重新凝出，不像 folia 那样停在落点。
- 融雪是简化版：窗外两层落雪，玻璃上的雪按透视飞来、粘住、化成一颗水珠再干掉。没有分珠合并物理、冰珠和冰点、火彩折射，写字的笔尖和抹字的手指扫过时也不会吸走雪水。凝露的水珠被写字吸走这一点同样没做（但擦开的地方没有水珠）。
- 水族箱：水母位置直接按时钟算出（不积分），只画伞盖、拖尾和光晕，水母的跟拍分项没有。气泡分成泉眼细泡（对应窗外的雨开关）和大泡（对应车灯开关）。
- 舍弃的 tuning：render（分辨率 / 抗锯齿，归宿主管）。多选项改了形式：出现 / 消失按 folia 快捷按钮的预设做成单选（auto/write/fade/breath，fog/fingers/mix）；9 种构图、5 样窗外显示改成逐项开关，构图全关时按全开处理。
- 减弱动态效果时：窗外静止，不颠簸、没有雨点和下淌水珠；字在开唱时整字显出（不逐笔写），手指抹除改为起雾，起雾和哈气照常按歌词时间走。
- 共用背景（behind=backdrop）时雾是半透明的雾色（深色主题用深灰、浅色主题用白），擦开处透出宿主背景，宿主背景本身不做模糊。

### 隐喻（metaphor）

- Audio: Fushi has no realtime loudness. folia's smoothed audioPower (it swells the blobs and strengthens the flow field) is replaced by runtime.pulseAt(t, decayMs: 600) × 0.6.
- Dropped the 'annihilation collision' beat effect (metaphorBeatFx.ts: collisions snapped to beats, small rings on every beat). There is no beat grid; collisions stay on word onsets, as folia does when the effect is off.
- Dropped the keywordColors tuning and the per-keyword tint output (uTint). Fushi's cover palette has no wordColors keyword list, so accent glyphs never occur and the accent channel is used only by accent blobs and rings.
- Dropped the render tuning (resolution multiplier). The ink field is drawn at logical resolution, capped at 960 px on the long side.
- No chorus flag in fushi_music LyricLine, so the chorus extras (more negative shots, more cuts, macro/dutch bias, flood/smash into the chorus) never trigger.
- No theme animationIntensity, so the pace factor is fixed at 1 (folia: calm 0.75 / chaotic 1.3).
- Word segmentation uses the runtime's split: one token per CJK character, Latin split on spaces. folia uses Intl.Segmenter word segmentation, so Japanese words like 夜空 become two tokens here, which affects the hero/scatter picks and camera word focus.
- No custom fonts shipped: lyrics use the default app font at w300, as in folia when the theme sets no weight. Notes use an italic serif fallback chain (Cambria Math / STIX / Georgia / Noto Serif / serif) and may render differently per platform.
- Threshold noise, grain and specks are pre-baked periodic tiles shifted per frame instead of per-pixel shader hashes. The grain tile shifts as a whole 6 times a second, so the paper mottle moves with the fine grain instead of staying still.
- The flow warp is a mesh of about 48 cells along the long side with texture coordinates displaced by the same value noise, not per-pixel. The fine 9× noise layer is sampled coarsely.
- Line-art edges are plain strokes (2× half-width × 1.1) plus one wider G-channel stroke for the halftone fringe, not the shader's smoothstep falloff. Bands wider than 0.06 world units are drawn unwobbled. Notes wobble as whole glyphs, not per pixel.
- The wide glyph blur is a text shadow (σ≈0.09 em) with a colour-matrix gain, standing in for folia's three-pass box blur. The atlas cell is 100 px with a 56 px em.
- Dropped the detail where an accent blob over unsung text darkens dots toward ink (`dots*accent*smoothstep(0.85,1,field.g)`).
- The ink field is 8-bit, not half-float, so overlapping blobs saturate at 1. folia's own fallback behaves the same way.
- Idle-time preparation of the next cue is replaced by building it synchronously in paint once it is less than 2.5 s away.
- The general font size setting (fontScale) is ignored, as in folia: the camera sets text size. Translation and next line are left to the host's shared subtitle (sharedSubtitle true), and sharedBackdrop is false because the style lays its own paper.
- Not checked on a real device, so Impeller frame cost is unmeasured. Each frame does one toImageSync of the field plus about 4 full-screen saveLayers.

### 花火（hanabi）

- 节拍特效（hanabiBeatFx）没做：Fushi 拿不到音频分析，也没有用 runtime.pulseAt 代替，烟花和镜头只按歌词时间走
- 副歌靠「相邻且在全曲重复出现的行」推断（folia 用歌词自带的副歌 / 段落标记）；段落结构靠行间隔和标点判断
- 分词按字符类别（汉字 / 假名 / 拉丁 / 韩文）粗切，folia 用 Intl.Segmenter，日文词界会有出入
- 21 种装饰件里，ring / spokes / orbit 照 folia 的参数移植，其余 18 种按 folia 的形状和节奏用 Canvas 自己重画（没逐行对照 ornamentShapes / Lines / Particles.ts）
- 拼贴层（collage：每镜头标题贴纸、爆点贴纸、whoosh 等）只保留了左缘胶片孔和右下角网点块两样
- 副歌整屏泛光用「把整层录成 Picture、模糊后用 plus 混合叠一遍」近似，没有 folia 的亮度阈值滤镜；low 画质不画泛光
- 烟花辉光滤镜（mg/glow.ts）改成每个光点额外叠一圈加色大光晕（SparkBatch.halo）
- 去掉了 folia 的渲染分辨率 / 抗锯齿调节项、开场标题卡和 lucide 图标；没用 folia 的字体或素材，字体跟随宿主 DefaultTextStyle
- 镜头坐标换算（screenToShot）没算镜头进场那一刻的世界漂移和转角，sky 型主烟花和间奏烟花的位置会和 folia 有几个像素到几十像素的偏差
- PREPARE_AHEAD 预备是在绘制里同步做的（下一段落提前 1.5 秒建装配、画字形图集），没有放到空闲帧里分摊，段落切换前一帧可能稍重
- 没有在真机 / 模拟器上看过实际画面，只跑了 widget 冒烟测试（不抛异常、卸载干净）

### 町景（machi）

- three.js 3D 改成 Canvas 2.5D：正交投影加画家算法（按物件中心深度排序），没有深度缓冲，相互穿插的物体可能叠错；圆柱用方杆代替；没有阴影贴图（folia 的阴影档位已去掉）
- 景深 / 移轴是近似：folia 按每个像素的深度算散景圆，这里按画面高度切 12 条横带分档高斯模糊，歌词屏所在的多边形不参与模糊；灯光不会虚成圆形光斑
- 后处理效果从简：bloom 改成加色径向光晕，没有横向镜头光条、色差、颗粒、FXAA/SMAA；墨线是给面描边，不是按深度二阶差分算的
- 湿地面倒影改成把发光体和灯在底座顶面上镜像成竖向模糊光带（不做真正的镜像渲染），水洼是按 seed 摆的半透明椭圆
- 音频驱动改用替代源：霓虹随拍 / 大屏闪拍用 folia 的固定节拍（simulated_beat，按氛围时钟走），屏幕亮度和点唱机读 runtime.pulseAt（歌词起字包络）；没有实时节拍检测、没有 HTDemucs 鼓点涟漪（machiDrumRipple 整个缺失）
- 副歌检测：Fushi 歌词没有 isChorus / songPart，改成把整首里唱过两次及以上的句子认作副歌（去掉标点、不分大小写）
- 自定义视角只存一份共享的五项滑块，没有按场景各存一份；不能在画面上拖动、滚轮缩放，也没有取景控制条 MachiCameraBar（拍板过：样式内不接手势）
- 画质类 tuning 去掉了（分辨率、抗锯齿、阴影、自动降级）；倒影和辉光留成两个开关
- 资源替换：folia 的主题图标（lucide）和自定义字体没带过来，店招 logo 改成封面色圆章加曲名首字母，字用应用默认字体；关键词着色（theme.wordColors）没做
- 细节简化：雨水沿屋檐的滴水、空调滴水和墙上水渍、白气（steam）、场地光柱、云与闪电的着色器没做，云和闪电改成模糊椭圆加整屏闪白；のぼり旗用剪切近似随风飘
- 字号：沿用 folia 的规则，场景里的字按屏幕和招牌大小自动排、不读 fontScale；fontScale 只作用于宿主的底部字幕（sharedSubtitle: true）
- 减弱动态效果时画静态帧：不画雨雪粒子、车、运镜、闪烁、节拍和闪电，湿地面、雾、积雪和换行照常显示

### 倾诉（tilt）

- 二次切分在 folia 里用 Intl.Segmenter 的 word 粒度（ICU 词典）。Dart 没有这个，改用近似规则（tiltWordLikeSpans）：拉丁和数字连写算一个词，平假名、片假名、谚文各自连写算一个词，汉字一字一词。中文多字词因此可能在词中间被切开。
- 字和段的时间取自运行时的字形时间线，不走 folia 的「按 words 找段的词范围」那套。逐字歌词下效果相同；行级（LRC）歌词在 folia 里所有段会同时出现，这里因为字形时间按行均分，各段会依次出现。
- 所有动画都按歌曲时间算，不按墙钟。暂停时过渡停在当前帧（folia 的 framer 动画暂停后还会继续播完）；拖进度时直接跳到目标时刻的状态。
- 上一句淡出时长、新句 0.3s 淡入取自 framer 默认 opacity 过渡（easeOut）。folia 里 activeLine 在句与句之间的空档是否为 null 没完全核实；这里一句起点一过就算当前句，唱完后各行淡出，但整组留到下一句开始。
- 新增两道防溢出兜底：整组高于 70% 屏高时整体缩小；单行宽于可用宽度时只压这一行。folia 窄屏下缩放有下限、会溢出被裁，这里改为保证完整显示。
- folia 量字宽时不计字距（pretext），这里照做；实际绘制带 0.08em / 0.15em 字距，由上面的单行兜底防止溢出。
- 字体用应用默认字体（folia 用主题字体栈），正体 w400、斜体 w300 加 italic；字体本身没有斜体字形时由引擎合成斜体。
- 这个样式本身不读音频；共享背景的 audioPower/audioBands 由宿主处理，与本样式无关。
- 未移植：OBS 和 mod 的 modKeys、播放面板里循环切换配色的快捷胶囊（Fushi 用通用参数面板代替）、「参数已重置」提示。

### 静止（still）

- folia Still 本身没有 tuning.ts，所以没有可调参数；规范要求的「非默认 tuning 组合」用两项代替：传一个无效 tuning 键的冒烟测试，加一个窄屏、fontScale 2.5 的测试
- folia 用 CSS scale 缩放（只改视觉、不重新排版），这里改成直接乘字号（会重新排版换行），长句在窄屏上能正确换行
- folia 的 theme.secondaryColor（译文色）在 Fushi 配色里没有对应项，用 Color.lerp(palette.text, palette.secondary, 0.35) 代替
- folia 的 hideTranslationSubtitle（全局隐藏译文）、subtitleTheme / subtitleFontScale（字幕单独的配色和字号）在 Fushi 框架里没有对应，译文总是显示，并跟随歌词字号倍数
- folia 的自定义字体栈（resolveThemeFontStack）和主题字重没有搬过来，用默认 app 字体加固定字重
- folia 的 effectiveIndex 用 state 记住上一句；这里改成纯按时间算（间奏里停在最近开始的那句），拖进度到间奏时结果更准确；正常往前播放时和 folia 行为一致
- drop-shadow-md / drop-shadow-sm 用近似的 Text shadows 代替
