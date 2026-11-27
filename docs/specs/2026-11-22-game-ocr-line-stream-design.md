# 游戏 OCR 台词流（OCR 游戏模式）设计

- 日期：2026-11-22
- 来源：拍板台 `v5GSgDau9u`（应用内反馈「希望添加基于 OCR 的游戏模式」，维护者拍板「做」）；
  与 BUG-5083（PR #4028 登记：GSM 式全游戏台词制卡，拍板台 `fMicnouU6V` ⑤ / `wkU3PmrlF0`）是同一个子系统，本 spec 一并覆盖。
- 平台：**只做 Windows**（与 galgame 制卡同一车道：窗口绑定、WGC 截窗、系统回录、台词工作台都是 Windows 专属）。
  不碰 Hook / 注入 / 引擎适配（`docs/agent/galgame-hooking.md` 的边界），OCR 模式**全程不注入游戏进程**。

## 1. 问题

Hook 模式只能覆盖注入得进去的游戏。联网游戏（注入有反作弊风控）、安卓模拟器里的游戏、引擎没适配的游戏，
现在只有悬浮球的一次性截屏识字（`screen_ocr_*`），没有「台词流」：没有台词历史、没有台词浮窗、
不能像 Hook 游戏那样一句一句带截图 / 语音制卡。

## 2. 目标（用户可见）

台词工作台多一个起点「OCR 识别台词」，与「启动并捕获」「附着到运行中的游戏」并列：

1. 选游戏窗口（复用现有窗口选择器）；
2. 在该窗口的一帧截图上**框选台词区域**（记住上次的框）；
3. 之后 Fushi 定时截这个窗口、只看框内：画面变了且稳定下来才 OCR，文本去重后作为一句台词进入
   **现有 texthooker 台词流**——台词列表、台词浮窗、点字查词、字数统计、制卡（截图取当时窗口画面、
   语音走系统回录 Loopback 逐句冻结）全部沿用 Hook 模式那一套，不另起一份；
4. 会话中可「调整识别区域」；停止监听 / 游戏退出即结束。

## 3. 架构（Rust 胖核心）

```
WindowCaptureChannel.captureWindow(hwnd)     ← 既有 C++ runner（WGC 单帧、客户区、PNG）
        │ png
        ▼  后台 isolate
ffc_ocrline_feed_png(tracker, png, region)   ← Rust：解码 + 裁框 + 帧签名 + 变化 / 稳定 / 空白判定
        │ action = idle | settling | ocr(rgba) | cleared
        ▼  只有 action=ocr 才往下
OCR 识别器（Windows.Media.Ocr 像素直传 / 本机模型 recognizeRgba）
        │ 行文本
        ▼
ffc_ocrline_feed_text_geometry(tracker, text, 逐字框)  ← Rust：拼行规范化 + 与上一句去重 / 打字机续写判定；
        │                                             逐字框对齐到显示文本、映回整张截图（第三期）
        │ kind = empty | duplicate | new | extend，text，glyphs（截图像素）
        ├──▶ GalOcrLineSource.measuredFeed（截图元数据 → 源客户区）→ attached surface 实测排版（游戏内嵌查词）
        ▼
TexthookerService.appendLine(source: screenOcr)   ← 既有台词流；extend 由既有渐进折叠并进同一行
        │
        ▼
GalHookSessionController（既有外部行路径：textSignal、字数、Loopback 逐句冻结、制卡）
```

**状态归属**：连续 OCR 的全部判定状态（上一帧签名、稳定计数、已送 OCR 的帧签名、空白态、上一句文本）
都在 Rust `OcrLineTracker` 里（`native/fushi_compute/src/ocrline.rs`），Dart 不存镜像：Dart 侧
`GalOcrLineSource` 只是泵——按间隔取帧、把帧交给 Rust、按 Rust 的 action 决定是否调 OCR、把 Rust 判出的
new / extend 行送进台词流。截窗（C++ WGC）与 OCR 引擎（WinRT / ONNX 会话）本来就不在 Rust，粗粒度命令
只有 `new / feed_png / feed_text / reset / free` 五个。

为什么不用 Dart 做判定：判定要逐像素扫裁出的区域（解码 + 灰度网格 + 边缘密度），是标准的「>1 ms、
逐元素」计算；放 Rust 一次 FFI 调用做完，后台 isolate 跑，不占 UI isolate。

### 3.1 帧判定（`feed_png`）

- 区域用**客户区归一化坐标** `(left, top, width, height) ∈ [0,1]`（窗口缩放 / 换分辨率后框仍对得上）。
- 帧签名：把裁出区域按面积平均降到 96×24 的灰度网格。两帧「变了」= 有 ≥2 个格子亮度差 > 18。
- 空白：裁出区域里水平边缘像素（相邻像素亮度差 > 40）少于 24 个 —— 台词框里没有字。用绝对数不用密度：
  宽台词框里只有「はい」这样一两个字时，按面积算的密度极低，会被误判成空白而永远不 OCR。
  从有字变空白时回 `cleared`，并清掉「上一句」，于是空白之后再出现同一句也算新的一句。
- 稳定：本帧与上一帧没变 = 稳定。只有「稳定」且「与上次送 OCR 的那一帧相比变了」才回 `ocr`
  并交出裁好的 RGBA（打字机逐字出现期间帧一直在变，不会 OCR 半句）。
- 闪烁的「点击继续」光标会让帧在两相之间来回，可能多送几次 OCR，但文本去重会把它们吃掉；
  这是有意的取舍（宁可多 OCR 一次，也不因为光标漏掉一句）。

### 3.2 文本判定（`feed_text`）

- 拼行规范化：逐行 trim；两侧都是 CJK（假名 / 汉字 / 全角标点 / 全角字符）时去掉中间空白（Windows OCR
  会在日文字之间插空格），行与行之间同理；其余空白折成一个空格。
- 去重键：去掉全部空白后的字符序列。与上一句的编辑距离 ≤ 10%（短句因此要求完全一致）→ `duplicate`。
- 续写：新键比上一句长，且新键的同长前缀与上一句距离 ≤ 10% → `extend`，输出 = 上一句原文 + 新增的尾巴
  （保证是严格前缀扩展，`TexthookerService` 的渐进折叠能把它并进同一行，行 id、Loopback 冻结起点都不变）。
  新键是上一句的近似前缀（变短）→ `duplicate`。
- 识别结果为空 → `empty`，同时清掉上一句（区域里确实没字）。

## 4. 会话集成

- `GalHookSessionState.ocrRegion`：非空 = 本局是 OCR 模式。
- `GalHookSessionController.startOcrCapture(window, region:, recognize:)`：走与 attach 相同的会话身份 /
  计时 / 游戏退出监视，但**不探位数、不找 helper、不注入、不连 Tyrano DOM**；音频直接起系统回录
  （受「音频降级」策略约束：禁止 Loopback 时只有文本），阶段 `waitingSignals`，第一句 OCR 行到达转
  `running`。不显示「已降级」：OCR 模式下 Loopback 是设计内的音频来源，不是降级。
- `setOcrRegion(region)`：会话中换框，Rust tracker `reset`。
- `_stopSourcesInternal` 停泵；`stopCapture` / 新的 launch / attach 都会先走它，所以 OCR 泵与会话同生命周期。
- 台词来源新增 `TexthookerLineSource.screenOcr`（sourceLabel `screen_ocr`），参与渐进折叠（与引擎行同理：
  同一句的多次快照）。

## 5. OCR 引擎

按「截屏识字」引擎设置解析（默认跟随全局 OCR 引擎）：本机模型就绪用本机模型，否则 Windows 自带 OCR。
**Google Lens 不用于连续识别**（每句都要上传整块画面，隐私与配额都不合适）：设置解析到 Lens 时退成
Windows 自带 OCR。识别器不可用（缺语言包 / 本机模型未下载）在开始前就报给用户，不起会话。

## 6. 分期

### 第一期（本 PR）

- Rust `ocrline` 域 + Dart 绑定 + 单元测试。
- Dart 泵 `GalOcrLineSource`（`fushi/lib/src/mining/gal_ocr_line_source.dart`）+ 会话集成 + 台词来源。
- 台词工作台「OCR 识别台词」起点、框选对话框、会话中「调整识别区域」，框选结果记在偏好里（全局一份；第二期改为按游戏记）。

### 第二期（BUG-5141，已做）

- **等待动画不再卡死稳定判据**（§3.1 补充）：每格记易变分（变一次 +2、稳一帧 -1，≥6 算易变），「稳定」与「与上次
  送 OCR 的帧比变没变」都排除易变格；打字机每格只出墨一次不会变易变；易变格超过网格四分之一视为整框在动，掩码作废。
- **送 OCR 前的预处理**（Rust `prepare_for_ocr`）：按有墨行段估字高，< 16 px 时整数倍放大到约 24 px（≤4 倍，最长边
  ≤2600 = `OcrEngine.MaxImageDimension`）；可选 Otsu 二值化（`ffc_ocrline_configure`，少数派当字、白底黑字）。
  交给识别器的 `width` / `height` 是预处理后的尺寸。
- **按游戏记住**识别区域与二值化开关（`GalCaptureMemory.ocrRegion` / `ocrBinarize`，key = 游戏 exe 全路径小写）；
  框选初值 = 本局 / 该游戏记住的 / 全局上次的框（偏好 `gal_ocr_region`，新游戏多半也是画面下方同类台词框）/ 默认框。
- **AI 操作目录**：`game.ocr.start`（`POST /api/admin/game/ocr/start`，不可逆：替换当前会话）、
  `game.ocr.region.set`（`PUT /api/admin/game/ocr/region`，可撤销）；`game status` 的 `session.mode = ocr` 带 `session.ocr`。

### 第三期（BUG-5299，内嵌查词已做）

- **持续 WGC 会话直出区域原始像素**：现在每次取帧都新建一次 WGC 会话并编 PNG，再在 Rust 解码；
  在 runner 里加持续会话 + 只回框内 BGRA（复用 `CaptureCore` 的 Magpie / 缩放源 / 客户区裁框判据），Rust 加
  `feed_bgra`，省掉编解码与会话建立（目标 ≥4 fps、单帧 <10 ms）。必须真机验。
- **OCR 行的游戏内嵌查词（已做，拍板台 wkU3PmrlF0 方案 b）**：识别器交出逐字框（平台词框内等分，其余行框
  等分，送检图像素）；Rust `ffc_ocrline_feed_text_geometry` 把框跟着拼行规范化对齐到显示文本（续写 = 上一句 +
  新尾巴、重复 = 上一句，都按第 k 个非空白字对齐；重复句字数变了不给几何），撤掉预处理放大、加回裁框原点，映回
  整张截图；`GalOcrLineSource` 再按这次截图的 `WindowCaptureMetadata` 换成源客户区物理像素（普通截窗恒等，
  Magpie 按源视口缩放 + 偏移；元数据缺失 / 不完整不猜），发布成 `GalMeasuredTextFeed`（mining 层中立接口，
  TyranoScript DOM 源同样实现）。attached surface 走现成的实测排版路线（`configureMeasured('screen_ocr')` →
  `updateMeasuredText`），点击查词不推进、输入屏蔽与 DOM 源完全相同；查词扫描面仍不 import OCR 包
  （`gal_attached_no_ocr_guard_test`）。画面在变（settling）/ 台词框清空 / 换区域 / 会话结束都先撤掉命中框。
  真机未验。
- 安卓模拟器以外的平台（macOS / Linux 窗口截取）不在范围内，除非用户改平台边界。

## 7. 测试

- Rust：`ocrline.rs` 单元测试覆盖帧判定（变化→稳定→OCR、未变不重复 OCR、空白 cleared、闪烁光标）与
  文本判定（CJK 去空格、去重、续写尾巴、变短、空文本清上一句）。
- Dart 绑定：`packages/fushi_compute/test/ocr_line_test.dart` 真 FFI 走一遍 PNG → action → text。
- 泵：`fushi/test/mining/gal_ocr_line_source_test.dart`（真 Rust tracker + 合成 PNG + 假截窗 / 假 OCR）。
- 会话：`fushi/test/mining/gal_ocr_session_test.dart`（不注入、起 Loopback、OCR 行进台词流且来源为
  screenOcr、停止监听停泵并清 ocrRegion）。
- 真机：未做（无可用的 OCR 目标游戏环境），缺口写在 PR。
