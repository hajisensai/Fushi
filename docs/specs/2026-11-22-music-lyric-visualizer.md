# 音乐歌词页：全屏歌词动画（移植 folia-major 的歌词动画样式）

- 日期：2026-11-22。所有者拍板：照 [folia-major](https://github.com/chthollyphile/folia-major)（commit `a772a97`）的
  全屏歌词动画做，**18 套样式全做**，「缺的能补齐就补齐」；全屏动画里**纯观赏、不点词查词**，点一下 / Esc / 返回键
  退出回原布局；**镜台（Diorama）用 flutter_gpu 做真 3D**（「大不了 fork」），拿不到 GPU 上下文的平台退回 CPU 版。
- 许可：folia 是 AGPL-3.0，本仓是 GPL-3.0。各样式是读懂 folia 算法后用 Dart 重写的移植（衍生作品），
  folia 的图片（头像 / 表情 / 纹理 / 图标）与字体一律没有搬进来，用封面、程序绘制、用户素材包和 Material 图标代替。

## 结构

| 位置 | 作用 |
|---|---|
| `fushi/lib/src/media/music/lyrics/visualizer/lyric_visualizer.dart` | 契约：`LyricVisualizerMode`（落库值 = folia 模式 id，冻结）、`LyricVisualizerContext`（音频 / 主题 / 强度 / 字幕 / 背景）、配色、可调参数（滑杆 / 开关 / 单选 / 颜色 / 文本 / 素材包，分组、条件显隐、预设）、注册项 |
| `.../lyric_visualizer_runtime.dart` + `_structure` / `_render_hints` / `_segments` | 共享运行时：当前行 / 间奏 / 离场窗口、逐字与逐词时间线（行级歌词按 folia 权重分配）、副歌 / 段落（来源标注优先，否则 folia 启发式）、renderHints、词级分组（按文字类别，无词典） |
| `.../lyric_visualizer_audio.dart` + `_beats.dart` | 音频契约：逐帧包络（power / low / lowMid / mid / upperMid / high / vocal / onset）、拍与强拍、每拍重音与音色、鼓击（底鼓 / 军鼓 / 镲）、人声起音；共享每拍特效强度（folia `resolveBeatFxAccentGain`）；没有分析时回落歌词包络 |
| `.../lyric_visualizer_theme.dart` + `ai_theme/` | 主题契约（配色覆盖、按词着色、强度、字体、名称 / 描述、图标闭集）；AI 主题（`AiFeature.musicVisualizerTheme`，每首缓存，可撤销） |
| `.../lyric_visualizer_background.dart` + `backgrounds/` | 背景层注册（fluid / solid / common / latent / monet / nomand / sora / url），样式按请求取背景并可覆盖背景参数 |
| `.../lyric_visualizer_subtitle*.dart` | 共享字幕（译文 / 罗马音 / 双行，全局隐藏 / 字号 / 字体） |
| `.../lyric_visualizer_assets*.dart` / `_cover.dart` | 用户素材库（`visualizer_assets/<样式>/<包>/`，逐张摆放）、共享封面加载 |
| `.../lyric_visualizer_frame.dart` | 唯一的逐帧驱动（Ticker → `LyricVisualizerTicks`，带 dt） |
| `.../modes/<样式>/` | 各样式实现（测试在 `fushi/test/media/music/visualizer/modes/`）；镜台另有 flutter_gpu 管线与 `shaders/diorama.shaderbundle.json` |
| `fushi/lib/src/media/music/analysis/` + `native/fushi_compute/src/music_analysis/` | 整首离线音频分析（Rust，`ffc_mana_*`）：DSP 退路 + Beat This! 节拍 / htdemucs 鼓与人声（ONNX，模型按需下载，GPU 执行器同漫画超分），结果 `.fma`（v3）缓存 |
| `fushi/lib/src/pages/implementations/music/music_lyric_visualizer_view.dart` | 宿主：背景 → 样式 → 共享字幕，悬停条（换样式 / AI 主题 / 退出）、选择面板、通用参数面板 |
| 歌词页 `music_lyrics_page.dart` | 工具栏「歌词动画」→ 选择面板 → 页内全屏层；进入时请求本首分析并预取下一首，退出即取消 |
| 设置 › 音乐 | 样式、每首随机、强度、背景、字号、字幕、自动 AI 主题、分析模型下载 / 删除 |

偏好键：`music_visualizer_mode` / `_random` / `_font_scale` / `_intensity` / `_background` / `_tunings`（JSON，
只存改过的项，背景参数在 `background:<id>` 下）/ `_subtitle_*` / `_ai_theme_auto`。

## 共性部分现状

最初登记的 9 项共性缺口（实时音频、副歌段落、renderHints、词级分词、强度 / 按词着色、参数类型、背景独立组合、
封面工具、用户素材）都已补上，见上表。仍存的共性差异：

- **分词没有词典**：功能黑名单禁止形态素分析，词级分组按文字类别（汉字 + 送假名、片假名串、拉丁词、中文逐字），
  与 folia 的 `Intl.Segmenter` 在中文多字词上不完全一致。
- **不搬 folia 素材**：内置头像 / 表情 / 装饰件 / 图标用程序绘制或 Material 图标代替，用户可用素材包替换。
- **按设计不做**：拖动 / 点句跳转等交互（纯观赏；莫奈除外，见莫奈小节）；OBS / mod 钩子、设置页内预览模式；渲染分辨率 / 抗锯齿参数
  （由宿主管）。
- **动画近似**：framer-motion 弹簧按解析曲线近似；动画按歌曲时间推进（拖进度结果确定）；换歌时场景重建，
  没有 folia 的 songHandoff 过渡。
- **镜台真 app 观察**：Windows 真机上 flutter_gpu 管线已建起（截图证据在 `fushi/.codex-test/windows-itest/diorama-gpu-*`）；
  Linux / Android / iOS / macOS 的 Flutter GPU 开关已配，未实机验证。
- **未在真机量帧耗**：CPU 近似重的样式（绘光、隐喻、花火、雾笺）低端机帧率未测。

## 待所有者拍板

- CI 每次在 shard 0 装 mesa（lavapipe）跑 flutter-gpu 标签测试，拿不到 GPU 判红：是否接受这份开销与依赖。
- 分析模型托管：目前从第三方 Hugging Face 仓库 `HUAI4236/folia-models` 下载（sha256 锁定）；是否迁到
  hajisensai/Fushi 的 release。

## 各样式与 folia 仍存的差异


### 流光（luminous）

- 弹簧按闭式解求值（stiffness / damping 与 framer 一致，含没写 transition 时 framer 的默认值：scale 550/30、
  opacity / filter `cubic-bezier(0.25,0.1,0.35,1)` 0.3 秒、只写时长的补间默认 easeInOut；颜色按 framer 的通道平方插值）；
  状态在弹簧中途切换时 framer 会带着当时的速度续上，这里从当时的位置以零初速续上，差别只在中断那一瞬
- 词的三态按歌曲时间求值，拖进度 / 暂停时停在确定的帧；folia 的 framer 动画暂停后仍会播完
- 无歌词行（首句之前）时 folia 显示「等待音乐」占位，这里不显示：需要新增 i18n key，属共享文件，留给宿主统一处理
- 副歌涟漪扩到的倍数 folia 用 `Math.random()`，这里按行起点与词序确定性取（仓库要求随机可复现）
- 「防止文字重叠」以外，单个词比行容器还宽时也按比例缩到放得下（folia 会溢出被裁）
- 字体栈：folia 按主题名映射到自带字体栈（resolveThemeFontStack），这里只认主题 fontFamily，否则用应用默认字体

### 心象（mindscape）

- 心象：pretext 断行用 TextPainter 近似，极端长词断点可能与 folia 不同（Flutter 无 pretext 库）
- 心象：folia 按 Canvas `actualBoundingBoxAscent`（墨迹顶）把词对到锚点，Flutter 没有墨迹边界接口，按字类估
  （CJK 0.84em、大写 / 数字 / 升部 0.73em、i / j 0.72em、其余小写 0.53em，`mindscapeInkAscentEm`）；CSS 行盒基线
  按字体自然 ascent / descent 精确算。字体墨迹与估值不符时词的纵向位置差几个像素
- 心象：folia 间奏里挂着 `ui.waitingForMusic` 的淡入占位，但该文案在 folia 各语言里都是空串，实际不显示；
  一比一即不画，Fushi 不加对应文案
- 心象：动效关闭（减弱动态 / 墨水屏）是 Fushi 宿主的能力，folia cadenza 没有对应规格：这时整句静止铺开，
  未唱的词透明度取 0.35、唱过的 0.82、不发光
- 已补齐（2026-11-23）：三层 40px text-shadow 逐层叠画（不再合成单层，辉光亮度 / 外晕与 folia 一致）；整行
  模糊在缩放后的坐标里做（CSS filter 在元素本地坐标）；副歌涟漪画在所有词之上（folia 的 canvas 叠在 DOM 上）；
  落点 id 照 folia 不含行号，相邻两句同位置同一词沿用动画状态、间奏清空；基线按 CSS line-height:1 行盒 + 墨迹顶对齐。
  folia 的 chaotic 行 `perspective` 只设在父层、子元素没有 3D 变换，实际不产生透视，无需移植

### 浮名（fume）

- 按词着色的「词」是运行时的词（CJK 一字一词）而非 folia 的歌词音节词，配合互相包含匹配，单字词命中含该字的关键字（如关键字「夜空」会染「夜」）
- 量字：folia 用 @chenglou/pretext；这里字号适配用 100px 的 TextPainter 自然宽度线性缩放，折行与字形偏移来自 TextPainter；主题未给字重时用 w800 / w600 近似 780 / 640
- 排版在首帧同步完成，不分时间片；folia 的「排版中」沙漏卡未移植，很长的歌首帧可能慢一次
- 唱过文字的标准→变暗交叉淡化画成一个插值样式（量化到 1/32），不是两层快照混合；字形相同，观感等价
- Canvas 2D shadowBlur 是屏幕像素：活动字辉光与方块模糊按镜头缩放折算，静态唱过块辉光保持世界单位（同 folia 缩放快照）
- folia 的 Linux 字形缓存绕行（FumeLiveRaster）与首帧过渡信号是 Chromium 专属，未移植
- 开始打印时 0.985→1 的放大是约 0.45s 的指数逼近，不是 framer-motion easeOut 补间
- 渲染质量覆盖（render.scale / antialias）与 mod 钩子不移植

### 云阶（partita）

- 云阶：中文没有词典分词，共享分词按单字切，中文语义分组只能按连续单字 CJK 词合并，与 folia 的 Intl.Segmenter 结果不完全一致（框架分词能力限制）

### 群唱（cappella）

- 群唱：没有内置 PNG 头像 / 表情素材，内置项仍用程序生成头像与程序贴纸代替（仓库不收 folia 美术素材，用户可用自定义素材包替换）
- 群唱：folia 的预览模式（设置页静态示例聊天）未移植（宿主设置页不渲染样式内预览）
- 群唱：气泡位置弹簧用解析阻尼曲线近似，不逐帧模拟 framer 弹簧
- 群唱：气泡文字对比度沿用固定深浅色规则，未接主题关键词着色（聊天气泡整段单色是 folia 原设计，按词着色会破坏可读性）
- 群唱：样式不使用音频帧（folia 群唱本身无节拍特效）

### 回环（claddagh）

- 弹簧在显示时间上推进（folia 在 rAF 真实时间上），拖动进度时会直接对齐，不走弹簧过渡。
- 主题字体没装时回落系统字体（框架不负责下载字体）。
- 字形缓存按量化后的半径 / 颜色建，极细微的颜色渐变会有台阶。
- 没有 folia 的 reset-hold 帧（换歌时先停一帧再起）：Fushi 换歌时整个场景重建。
- 译文环不做副歌错位（folia 只对主歌词环错位，译文环本来就不错位；保持一致）。

### 莫奈（monet）

- 肖像不能在画面上拖动 / 方向键挪位（folia 悬停出竖条手柄、改完写回参数）：样式上下文没有写回参数的回调（共享契约），用参数面板滑杆代替，手柄不画。
- 频谱条只从共享音频帧的五段频带插值：`LyricVisualizerAudioFrame` 不带原始 FFT（共享契约），folia 有原始频谱时直接取样。
- 没有 songHandoff 渐进交接（混音过渡中点切字、封面随过渡进度淡入）：上下文没有交接进度（共享契约），换歌整组重新入场，封面按 0.9 秒叠层淡入。
- 背景换歌时不先显示带主题色调的原始封面：烘焙通常 <200ms，期间显示上一张或兜底渐变。
- 背景烘焙按视口取 16:9 盖住框（宽 128 取整，640–2560 物理像素），folia 固定 1920×1080 拉伸；4K 屏上 Fushi 更清晰。
- 浮动装饰只复现 1px 描边观感，字形来自 Fushi 图标（不搬 Lucide 图形）。
- 超列宽长单词：Flutter 排版会在词中强制断开，没有 folia 的溢出 + 行尾渐隐。
- RTL 只按整行方向排版与扫光，行内混排的拉丁 / 数字不单独重排（与 folia 一致）。
- 描述胶囊悬停区 = 胶囊 + 上方 16px，没有 folia 左右 / 下方各外扩 24px（Flutter 命中测试不出父级边界）。
- 已补齐（2026-11-23）：描述胶囊 / 竖长方形肖像框的局部 BackdropFilter 毛玻璃（ClipRRect 限定区域）；chaotic→normal 0.8s easeOut 回正；背景先模糊后逐像素处理、旧图淡出新图淡入同时进行；封面 0.9s 叠层淡入（最多 4 层）；同音节字形不拆行；译文超两行截断 + 底部渐隐；RTL 扫光；滚轮 / 触摸手动翻行、1.8s 回到当前句、点句跳播（经已有的 `context.onSeek`）。
- 歌词栏交互照 folia 保留（所有者 2026-11-23 拍板）：滚轮 / 触摸手动翻行、点句跳播；点在歌词行上跳播、不触发宿主「点画面退出」，栏内空白处照常退出。

### 镜台（diorama）

- CPU 回退路径没有细纹贴图（只有 GPU shader 有 detail），CPU 点数占比固定 0.5。
- 2.5D 近似：没有真正的深度缓冲遮挡，按层序画。
- 没有 folia 的「等待音乐」占位与就绪门。
- 关键词对比度在 sRGB 空间算（folia 在 THREE 线性空间），个别颜色修正量略有差别。

### 时计（pendolo）

- 拍点列表驱动的冲击波透镜、齿轮火花、齿轮随拍步进不做：folia 2026-10-17 已退役（代码保留但关闭）。
- 封面在表盘上按 512px 缩放后居中裁成正方形（folia 直接拉伸）。
- 副歌光晕用遮罩后模糊叠两层近似 CSS mask 后的 drop-shadow，扫光前沿处光晕略被裁短。
- 手动滚轮 / 触摸转动弧线、点句跳转、手动滚动时的副歌标记点按设计不做（可视化只显示）。
- 轮心视角用透视投影近似 folia 的 DOM rotateX / preserve-3d，没有层间深度遮挡；倾斜 / 视差也按层高顺序画，不做深度 / 模板遮挡。
- 线条发光用录制机芯 Picture 后模糊着色两层（sigma 6 / 2）代替 CSS drop-shadow 4px / 12px。
- 去掉了 render（分辨率 / 抗锯齿）参数：Flutter 下没有意义。
- 句子旋转 / 缩放以弧上锚点为轴，folia 以盒子左中点（-50% 平移前）为轴，相差半个块高。
- 没有歌词时轮盘立即每 5 秒走一格，没有 folia 3 秒 READY_GRACE 等纯音乐判定。
- 非焦点句变焦点句时字号直接切换，没有 folia 200ms 的 CSS 过渡。
- 摆轮图标用 Material 实心字形，不是 Lucide 描边，且不随镜像翻转。

### 商籁（sonnet）

- folia 100 种几何主图只移植 0–17，18–99 是主题插画类素材，按「不复制 folia 素材」不移植
- textureResolution 与渲染覆盖类参数不移植：分辨率 / 抗锯齿归宿主管
- 着色器加载失败时 CPU 回退只有 RGB 错位和暗角，镜头扭曲、色散、网点需要逐像素着色器
- 故障条转场合并成 14 条粗带、胶片颗粒用随机点近似：CPU 逐条重画 58 条细带开销过大
- 导引线和圆的起笔用种子随机而非 Math.random：仓库规定随机必须可复现，属有意差异
- 深度视差比 folia 简化：没有深度缓冲
- 只有单元测试与 widget 冒烟测试，未在真机上看过画面
- 主题图标粒子用 Material 实心字形；主题没有名字时角标回落曲目信息（曲名 / 艺人 — 专辑）。

### 凝彩（tempera）

- 文字反色在 CPU 上按块形近似，没有 folia 的逐像素着色器和 5 点平滑
- 后处理（镜头扭曲、RGB 错位、纹理压缩 / 分辨率）不移植：需要全屏着色器，分辨率归宿主管
- 景深模糊在绘制时用 ImageFilter.blur，没有预烘焙进纹理
- 用 TextPainter 量字而非 pretext，字形缓存按 1/32 量化透明度
- 跨会话换歌交接与逐帧一项的场景预加载调度器未移植：场景缓存按需懒建、保留当前段 ±1 已够用
- 墨块是 CPU 曲线，不是噪声纹理 + 片元着色器；封面图层固定默认摆放。

### 绘光（lumiere）

- 光场在 CPU 上按网格顶点算再插值，没用片元着色器：窄光丝、焦散、干涉条纹偏软；低端机建议均衡 / 省电画质，未在真机测帧率
- 图形辉光与文字辉光是近似做法（加宽描边、光点光晕、眩光放大），没有全屏模糊 bloom 后处理
- 响度在这里抬的是烟雾受光增益，folia 抬的是烟雾密度系数：本移植的雾密度在网格着色里已固定，视觉效果相近
- 背景歌词碎片用实心字低透明度画，不是 folia 的空心描边字
- 竖排只在当前行以 CJK 为主时启用（拉丁行不转写）；纵横排版简化为固定槽位，没有完整移植 lineClearance / windowProtection 避让
- folia 原文 prismTriangle 线稿函数体被截断，按名称和调用参数重建
- folia 用户上传的自定义字体不移植（主题字体已接上）
- 用 TextPainter 量字而非 pretext，槽位间距按字号重新标定
- 只有单元测试与 widget 冒烟测试，未在真机上看过画面
- 主题图标整体淡入，不逐笔描绘；避让的是分镜自身的文字区，不是单元领句区域。

### 雾笺（nebbia）

- 小雨点没乘 folia 的整首响度归一（songLoudness）：框架人声包络已归一到 0..1
- 舞潮踏拍的冒泡排（bubble rows）没做；folia 各分项独立强度合成一个滑块
- 没有 AnimCJK 笔顺数据（APL 授权，folia 也不入库）：笔顺按字体骨架从上到下、从左到右估，骨架生成好之前用扫笔字形
- complexScale（10 笔以上的字放大）依赖笔顺数据，未实现
- 折射、雾浓淡、擦痕毛边是 CPU 近似（暗色水珠身 + 折光 + 高光、软斑、MaskFilter 模糊），没有噪声阈值与真实折射采样
- 颠簸后的弹簧甩动与甩出的印子（smears）未移植；震落的水珠回雾后回原处重新凝出
- 融雪简化：没有分珠合并物理、冰珠冰点、火彩折射，笔尖和手指不吸雪水；凝露水珠不被写字吸走
- 水族箱水母位置按时钟直接算（不积分），只画伞盖、拖尾、光晕
- render 分辨率 / 抗锯齿归宿主管；出现 / 消失与构图 / 窗外的多选按 folia 快捷预设改成单选 + 逐项开关
- 主题强度与按词着色不接：folia 雾笺本身不读 animationIntensity / wordColors，不算差异
- 只画有线稿的 10 种主题图标，其余跳过（不搬 Lucide 资源）。
- 水母上浮没有加跟拍的额外速度（folia 0.06×kick）：上浮位置按时间直接算、没有逐帧累计状态。
- 水母自身节奏 1→0.4 直接切换，没有 folia 1.5 秒渐变；水草仍跟连续拍点包络，没有移植每拍左右交替的弹簧。

### 隐喻（metaphor）

- 渲染分辨率倍数没搬：Flutter 按设备像素比画，这一项没有意义
- 墨场是 8 位 / CPU 近似（阈值噪声贴图、流场网格、线稿描边、文字阴影模糊），没有 folia 的 GPU 浮点墨场
- 强调融球压在未唱字上让网点变暗的细节没做
- 关键字着色用 srcOver 叠色近似 folia 的 tint.rgb / tint.a 混合
- 没有自带字体，注记字体回落到系统字体
- 下一个 cue 的预备是同步构建，没有放到空闲帧
- 没在真机上量帧耗

### 花火（hanabi）

- 18 种装饰件是重画的近似，不是 folia 原图
- 拼贴层做了简化
- 泛光与辉光滤镜是近似实现
- 去掉了分辨率 / 抗锯齿 / 开场卡几项（Flutter 侧没有对应意义）
- 镜头坐标换算不含漂移与转角，随拍烟花落点同样有这个偏差
- 下一段预备是同步构建
- 分词没有词典，按文字种类近似
- 没在真机上量帧耗

### 町景（machi）

- 2.5D 场景、后处理、倒影和细节都做了简化
- 没接手势和取景条
- 画质项去掉了
- 资源是替换品，不是 folia 原资源
- 字号规则做了近似

### 倾诉（tilt）

- 共享词级分组无词典：中文按字切、日文长汉字复合词（>4 字）退回逐字，与 ICU 带词典的 Intl.Segmenter word 粒度仍有出入，二次切分可能落在中文多字词中间（框架明确不接形态素分析，功能黑名单）
- 所有动画按歌曲时间而非墙钟：暂停时过渡停在当前帧、拖进度直接跳到目标状态（folia framer 动画暂停后仍会播完）——有意为之，保证拖进度结果确定
- 新增两道防溢出兜底（整组过高整体缩小、单行过宽单独压缩），folia 窄屏会溢出被裁
- folia 自定义字体栈未搬入（只用主题 fontFamily 或应用默认字体），字体无斜体字形时由引擎合成斜体
- 不移植：OBS / mod 的 modKeys、播放面板循环切换配色的快捷胶囊（用通用参数面板代替）、「参数已重置」提示

### 静止（still）

- folia 用 CSS scale 只改视觉不重排；这里直接乘字号重新排版换行（有意：窄屏长句能正确换行）
- 只有封面取色（无 AI 主题）时译文色是正文色与 secondary 的 35% 混色，非 folia 封面主题的 secondaryColor（封面 ColorScheme 的 secondary 是 M3 色调，暗底上常不可读）
- folia 的 effectiveIndex 用 state 记上一句；这里纯按时间算（间奏停在最近开始的那句），拖进度到间奏更准，正常播放一致
- folia 自定义字体栈（resolveThemeFontStack 的主题名 → 字体栈映射）未搬入，只认主题 fontFamily
- drop-shadow-md / drop-shadow-sm 用近似的 Text shadows 代替
- folia Still 无 tuning.ts，没有可调参数
- 会显示罗马音行和双字幕，比 folia 静止多（全局字幕设置统一）。
