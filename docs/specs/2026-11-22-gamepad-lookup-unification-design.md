# 手柄查词统一：一套查词模式（2026-11-22）

来源：拍板台 TNLH5FvQs_（扫词加字符级微调）。用户 2026-11-22 拍板「重新设计手柄查词」，四项选择：

1. **统一成一套**：`ControllerLookupMode` 是唯一的手柄查词。删掉视频「整句扫词」（`videoLookupNextWord` / `videoLookupPrevWord`）与光标模式的手柄入口（键盘光标保留）。
2. **单屏也默认按住 L1**（原来单屏默认关，只有副屏在时默认按住 L1）。
3. **停下即查**：光标停到新位置就自动查，不再先按 A。
4. **边界微调用右摇杆左右**，并且**查词模式的键位全部可在快捷键设置里改**。

## 为什么要统一

改之前有四套手柄查词，键位互相矛盾：

| 路径 | 制卡 | 发音 | 问题 |
|---|---|---|---|
| 光标模式（阅读器 A / 视频 Select 进） | 无 | 无 | 模态吞键，进去就制不了卡 |
| 视频扫词（默认不绑定） | 弹窗兜底 X | 弹窗兜底 Y | 只视频有，默认找不到 |
| 弹窗兜底键（dictionaryPopup scope） | X | Y | 页面先吃键，阅读器 X/Y 被书签 / 顶栏占 |
| 查词模式（L1 / Select） | 再按 A | X | 单屏默认关 |

## 键位（新 scope `controllerLookup`，全部可改键）

| 动作 | 默认 | 说明 |
|---|---|---|
| 光标左 / 右 | 十字键 ← / → | 按词（粒度切到「字」后按字）；停下即查 |
| 上 / 下一行 | 十字键 ↑ / ↓ | 字幕句 / 文本行 / 歌词行 / OCR 块；停下即查 |
| 切换按词 / 按字 | L3 | 用来挪选区左端 |
| 选区右端 −1 / +1 字 | 右摇杆 ← / → | 重查，命中长度受这个上限约束 |
| 制卡 | X | 与弹窗兜底键、游戏内查词卡片同键 |
| 发音 | Y | 同上 |
| 下 / 上一词条 | RT / LT | |
| 进入结果（弹窗内选词 / 嵌套查词） | A | 单屏页内弹窗才有意义；副屏查词页时无动作 |
| 关闭结果 / 退出模式 | B | 先关结果，再按退出 |

- 左摇杆仍等同十字键（不可改键的固定通道，与 TODO-700 T6 一致）。
- 右摇杆纵向仍是连续滚动结果（模拟量，不进注册表）。
- 进入模式的键不进注册表：仍由偏好 `controller_lookup_style`（按住 L1 / Select 切换 / 关）决定。

与旧查词模式键位相比的变化：制卡从「再按 A」改到 X、发音从 X 改到 Y、粒度切换从 Y 改到 L3、A 改成「进入结果」。理由：X / Y 是全 app 弹窗兜底键与游戏内查词卡片的制卡 / 发音键，模式内跟它们一致，用户松开 L1 后对着同一个弹窗仍按同一个键。

## 右摇杆左右成为可绑定的虚拟键

`GamepadButton` 新增 `rightStickLeft` / `rightStickRight`（标签 `RS←` / `RS→`，逻辑键 `gameButton15` / `gameButton16`）：

- 桌面轮询器：右摇杆横轴带滞回的边沿检测（与左摇杆同阈值），出 press / release，按住时由查词模式自己的 400 / 150 ms 连发。
- Android：`GamepadTriggerKeySynthesizer` 把右摇杆横轴（`AXIS_Z`，设备没有时退 `AXIS_RX`）合成 `KEYCODE_BUTTON_15` / `KEYCODE_BUTTON_16`。与扳机同一套滞回，不消费 motion event。
- 只有查词模式消费它；其它 scope 不给默认绑定。

## 「停下即查」与选区右端

模式持有 `_maxGraphemes`（`int?`，null = 不限，交给词典最长匹配）：

- 任何光标移动（词 / 字 / 行）都会把 `_maxGraphemes` 清为 null，然后查词。
- 连发期间不查，松开方向键（或连发停止）时查一次；单击步进立刻查。理由：150 ms 一步连查会让弹窗反复换内容，查词流水也会被一路作废。
- 右端 −1：`_maxGraphemes = (上次命中长度 ?? 已查长度) − 1`，最小 1；右端 +1：`+1`，超过本行剩余字数就回到 null。上次命中长度由页面 `lookupAtCursor` 返回（`searchDictionaryResult` 的高亮长度）。
- 页面在拼查询词时把从光标起的文本截到 `_maxGraphemes` 个字素，其它不变。命中长度不变时页面高亮不变，用户靠弹窗词头看结果。

## 光标留在正文

自动查词后**光标不再自动转进弹窗**（旧行为：单屏弹窗渲染后光标 transfer 进弹窗，`routerOwnsInput` 变 false）。否则下一次十字键会在弹窗里走，而不是在正文换词。要在弹窗里选词，按「进入结果」（A），这时才把光标交给页面既有的弹窗光标，`routerOwnsInput` 变 false，B 退回正文。

## 删掉的东西

- `videoLookupNextWord` / `videoLookupPrevWord` 动作、`word_sweep.part.dart`、`advanceSubtitleSweepIndex` / `resolveSubtitleSweepStop` 及其测试。分词器 `buildSubtitleSweepTokens` 保留（查词模式步进在用）。
- `videoEnterCaret` / `readerEnterCaret` / `readerLookupAtCursor` 的手柄通道（`channels` 去掉 gamepad，默认手柄绑定删掉；已存的自定义手柄绑定随之失效且不再显示）。键盘通道不动。
- 旧的持久化 key `video_lookup_next_word` / `video_lookup_prev_word` 加载时忽略。

## 默认开启的行为变化

单屏也默认「按住 L1」后：有查词目标的页面里，L1 的轻点改在**松开**时按原绑定补发（阅读器 LB 翻页在松开时触发）。不想要的用户在「通用 › 键盘与手柄」改成「Select 切换」或「关」。

## 实现分块

1. 核心（`shortcuts/` + `second_screen/input/`）：scope / 动作 / 默认 / 标签 / i18n，`GamepadButton` 虚拟键与桌面轮询，查词模式改为查注册表、停下即查、右端上限，目标接口改版，默认风格。
2. 页面适配（各自文件）：阅读器、视频（含删扫词与光标手柄入口）、漫画、歌词。
3. Android 合成右摇杆横轴。
4. 文档（shortcuts-inventory / second-screen）、测试、守卫。
