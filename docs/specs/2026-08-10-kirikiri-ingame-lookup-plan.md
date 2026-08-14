# KiriKiri/KAGEX 游戏内查词实现计划

> 状态：已实现，等待最新真实游戏 E2E；支持能力保持 `implemented_unverified`。
> 平台边界：**仅 Windows**（galgame 硬规则，见 [CLAUDE.md](../../CLAUDE.md)）。
> SOP：[docs/agent/galgame-hooking.md](../agent/galgame-hooking.md)。

## 0. 一句话

沿用 v14 的单一 UI 真值：**Fushi 在离屏 WebView2 中渲染完整 popup，截成 BGRA 位图后回投到游戏
`Layer`；游戏进程只做文字几何、命中、高亮、位图显示和输入转发。**

这不是让 Hibiki 再弹一个桌面窗口，也不是在 TJS 中重写一套词典卡。屏幕上唯一可见的卡片属于游戏
渲染树，卡片内容与交互仍复用 Fushi 的既有 popup 实现。

## 1. 既有事实

### 1.1 样本与执行边界

| 项 | 值 |
|---|---|
| 引擎 | KiriKiri Z + KAGEX，第三方 `textrender.dll` 排版 |
| 架构 | 当前目标游戏及所需 helper/hook 为 Windows x86 链路 |
| 有效文字边界 | `TextRender.render/done` + `renderer.getCharacters(0, 0)` |
| 绘制宿主边界 | `TextRender.drawCh(layer, ox, oy, ch)` |
| 完整性边界 | 只注入内存，不修改游戏目录下任何文件 |

此前运行证据已证伪把 `MessageLayer.processCh`、全局 `Layer.drawText` 或
`msdfrender.dll!drawGlyph` 当成生产捕获主路。`iTVPFunctionExporter` 官方 ABI 与
`TVPAddContinuousEventHook` 主线程 bootstrap 时序继续保留。

### 1.2 Fushi 可复用的真值

| 能力 | 唯一实现 |
|---|---|
| 查词、去屈折、复合词选择与词典优先级 | Fushi lookup dispatcher / dictionary model |
| ruby、外字图、词条展开、发音、制卡、主题与多语言 | `fushi/assets/popup/popup.html` |
| 离屏 WebView2 合成、截图和鼠标输入注入 | `GlobalLookupWindow` |
| galgame 会话、语音与截图制卡上下文 | Fushi galgame lookup/mining controller |
| hook↔host 控制、hit、input 与 frame | v14 共享内存 IPC |

## 2. 所有权决策

卡片只能有一个**可见所有者**：游戏渲染树里的 KiriKiri `Layer`。卡片也只能有一个**内容/排版
实现**：Fushi popup。

| 职责 | 所有者 |
|---|---|
| 逐字几何、光标命中、即时字幕高亮 | 游戏进程内的 TJS 传感器 |
| 本地查词、分词、完整句子与制卡上下文 | Fushi Dart |
| HTML/CSS 排版、词条交互、发音与制卡按钮 | Fushi `popup.html` + 离屏 WebView2 |
| BGRA 截帧、帧校验与共享内存发布 | Windows runner |
| 位图复制、游戏内 Layer 可见性与输入转发 | hook DLL + KiriKiri TJS |

因此生产主路明确禁止：

- 在 TJS/C++ 中维护第二套词典、HTTP、认证 token、JSON 或卡片排版；
- 用 `Layer.drawText` 重建 popup 的标题、释义和按钮；
- 把离屏 `galCard` HWND 当成第二张桌面可见卡；
- 把词典返回字符串拼进动态 TJS 源码；
- 用模块存在、attach 成功或旧截图替代本轮真实游戏 E2E。

## 3. 数据流

```text
┌─ 游戏进程 / KiriKiri ──────────────────────────────┐
│ TextRender.render/done → glyph[]                    │
│ TextRender.drawCh         → 宿主 layer + 绘制原点    │
│ KAG mouse/key hook                                   │
│   hover  → 本地高亮                                  │
│   submit → 耐久快照 → LookupHitSlot                  │
│   card input → LookupInputSlot                       │
└─────────────────────────────┬────────────────────────┘
                              │ v14 shared memory
                              ▼
┌─ Fushi host ─────────────────────────────────────────┐
│ runner → onGalLookupHit                              │
│ GalIngameLookupController                            │
│   → GlobalLookupController.lookupText                │
│   → target = galCard                                 │
│   → popup.html @ offscreen WebView2                  │
│   → CapturePreview 得到预乘 alpha 的 BGRA             │
│ runner → LookupFrame 双缓冲发布                       │
└─────────────────────────────┬────────────────────────┘
                              │ v14 shared memory
                              ▼
┌─ 游戏进程 / KiriKiri ──────────────────────────────┐
│ 校验 seq/hit_seq/尺寸/pitch/容量                    │
│ memcpy BGRA → card Layer                            │
│ Apply(seq, highlight_start, highlight_len)          │
│ 转发 popup 内鼠标/滚轮/按键 → Fushi → 新 BGRA 帧     │
└─────────────────────────────────────────────────────┘
```

**位图永远不经过 Dart。** Dart 只负责查词、popup 编排与语义上下文；WebView2 到共享内存的像素链路
留在 C++ runner，游戏侧只消费结构化整数和 BGRA。

## 4. 几何与消息层身份

### 4.1 common-root 坐标换算

命中计算同时维护两套坐标，禁止混用：

- primary **图层坐标**：光标命中、高亮层和父链关系；
- primary **图像坐标**：`imageWidth/imageHeight`、字形矩形、popup anchor 与位图尺寸。

KAG 的 back page 可以是 primary 的兄弟子树。`fushiLookupComputeOffset` 分别沿消息层与 primary 的
父链（各自有界）累加到共同根；只有根对象相同，才发布 `layer - primary` 偏移。异根、父链环或遍历
超限都 fail closed，不能把 sibling-local 坐标误当 primary-local 坐标。

### 4.2 `hostPage/currentNum` 锚点

`drawCh` 的逐字子层不是可靠的屏幕锚点；KAG 真实消息层位于 fore/back 双缓冲页。身份选择顺序固定为：

1. 由 `best.host` 判定实际绘制宿主页 `hostPage`；
2. `kag.currentNum` 是有界整数时，选择该宿主页的 `messages[currentNum]`；
3. 否则以 `kag.current` 的**对象身份**在 fore/back 找逻辑下标，再投影到宿主页；
4. 两条路径都失败才退回 `best.host`。

不能按名称、尺寸或跨页第一个相似对象猜测身份；同页可能有多个同尺寸消息层，fore/back 也可能各有
同一逻辑下标。

## 5. v14 IPC 与内存预算

`kSharedVersion == 14`。查词区保持三条单写单读通道：

- `hit`：hook → host，单槽 latest-wins，发布完整句子、字符索引、字形矩形和视口；
- `input`：hook → host，环形缓冲，坐标已换成 popup 局部坐标；
- `frame`：host → hook，双缓冲 BGRA，`ready` 与 `seq` 最后发布。

每个 frame 的位图容量为 **8 MiB**（`kLookupBitmapBytes = 8 * 1024 * 1024`）。runner 在截帧前按
`pitch * height` 复核容量；hook 侧再次验证 width、height、pitch、byte length、slot 与序号。超预算帧
必须缩放/重排后重新捕获，不能截断或越界复制。

`LookupFrame` 的两个序号不可合并：

- `seq`：host 每次 present/dismiss 的发布序，用于双槽下标、去重与重连恢复；
- `hit_seq`：该帧回应哪次 submit，用于拒绝被更新 submit 作废的异步查询结果。

## 6. 输入、竞态与生命周期

### 6.1 hover 本地，submit 耐久

hover 只更新游戏线程里的视觉序与字幕高亮，**不写共享 hit 槽**，也不能覆盖尚未被 host 消费的点击。
点击时先写完整句子、字符范围、字形矩形与视口，再以 `SubmitSeq` 最后发布；C++ 读取全部字段后复读
`SubmitSeq`，只接受两次一致的快照。

Esc、换行/换页、禁用或会话关闭都会发布 dismiss fence。迟到的查词结果、帧或输入必须同时通过
presented、当前 hit、当前 submit 与 dismissed submit 的契约判据，不能让旧卡复活或收掉新卡。

### 6.2 frame snapshot 与二次确认

runner 发布 frame 时先写 staging，再复制到目标 slot，最后写 `ready/seq`。hook 消费时先抓完整快照，
校验后在真正复制前二次确认 slot 的 `ready/seq/hit_seq` 未被复用；确认失败只做有界重试，永久非法帧
直接拒绝。只有 BGRA 已复制、卡层已更新且高亮成功后，才能推进 presented cursor。

### 6.3 enable 失败重试

开启游戏内查词时，若同一 active session 的首次 `galLookupSetEnabled` 因 reader/helper 尚未就绪失败，
控制器不能把失败缓存为“已启用”。同一 session 后续同步必须重试；换 session 或关闭时用 generation
使旧 enable/lookup future 失效。异步查词同样 latest-wins，旧 generation 返回不得落屏。

## 7. Fushi popup 的嵌入模式

### 7.1 只隐藏顶部整句横幅

游戏内调用复用 `GlobalLookupController.lookupText`，仅传：

```dart
showSentenceBanner: false
```

它只隐藏 popup 顶部重复显示的整句横幅，不删除查询词、释义、词典标签、发音、收藏、制卡、主题、
滚动或展开能力。完整原句仍传入 popup/mining 上下文，所以制卡字段与当前语音、截图关联保持完整。

这不是新增一套“游戏内精简卡片”；它是同一 popup 的显示选项，因此阅读器、视频、全局查词与 galgame
不会产生行为分叉。

### 7.2 `galCard` 必须始终离屏

Windows 会把普通 `SetWindowPos`/resize 的离屏顶层窗口按 work area 钳回桌面，造成用户看到一张
WebView popup，同时游戏 Layer 又显示一张位图卡。`GlobalLookupWindow::ResizeOffscreen` 专用于
`galCard`：resize、reveal 与 revealStack 都固定在 `OffscreenX(), 0`，同时保持 `visible=false`、
`revealed=false`。

因此 `galCard` 可以完成布局与 `CapturePreview`，却永远不成为第二个桌面可见所有者。普通全局 popup
继续使用既有的可见窗口路径，二者不互相污染。

## 8. 游戏内位图落地与交互

主路每帧重新获取 `Layer.mainImageBufferForWrite` 与 `mainImageBufferPitch`，不缓存可能因 copy-on-write
或 resize 失效的指针。校验通过后复制预乘 alpha BGRA、更新 Layer，再应用命中词高亮。

popup 矩形内的鼠标、按键与滚轮以局部坐标回送 Fushi，并复用 `GlobalLookupWindow::SendMouseInput`；
Fushi 产生的新视觉状态仍通过下一张 BGRA 帧回投。popup 外事件继续交给游戏，不允许全局吞键或改变
游戏的双击/文字选择语义。

`Esc`、台词更新、禁用、会话结束或查词无结果均走显式 dismiss frame；不能用 `width == 0` 之类魔法
编码，也不能依赖桌面 HWND 隐藏状态推断游戏 Layer 生命周期。

## 9. 风险与非目标

| 风险 | 处理 |
|---|---|
| `mainImageBufferForWrite` 指针随 Layer 变化失效 | 每帧重取，不缓存 |
| 高分辨率 popup 超过 8 MiB | host 重排/缩放并重新捕获，双方拒绝越界 |
| WebView HWND 被 work-area clamp 回桌面 | `galCard` 的三条尺寸/揭示路径统一 `ResizeOffscreen` |
| hover 覆盖点击或迟到帧复活 | hover 本地化 + submit/frame 双 fence |
| helper/host 版本漂移 | v14 两侧同一构建产物；版本不符时关闭查词区而非盲读 |
| 泛化过度 | `textrender.dll` + `TextRender.getCharacters` 双门；缺失即不启用 |

非目标：Android、iOS、macOS、Linux；在游戏进程实现词典或网络；修改游戏磁盘文件；仅凭一次 attach
宣称所有 KiriKiri 游戏已支持。

## 10. 验证门与实施记录

### 10.1 本轮已落地

- common-root 父链坐标换算，以及异根/环/超限 fail closed；
- 以实际 `hostPage` 投影 `currentNum`，对象身份为 fallback 的消息层锚点；
- hover 本地高亮、耐久 `SubmitSeq` 快照、Esc/dismiss fence；
- frame staging snapshot、slot 二次确认、成功后才推进 presented cursor；
- 同一 active session 的 enable 失败可重试，Dart lookup generation latest-wins；
- `galCard` 专用 `ResizeOffscreen`，阻止 resize/reveal 被 Windows work area 钳回桌面；
- 嵌入查词使用 `showSentenceBanner: false`，只隐藏顶部整句横幅，保留 mining 上下文与完整 popup 能力；
- v14 单帧 **8 MiB** BGRA 容量与两侧尺寸/容量校验。

### 10.2 本轮明确未证明

按用户要求，**本轮未运行测试、guard、生成器或 CTest**。自动化源码存在不等于通过，文档也不得把
代码落地写成真机支持。

支持状态继续保持 `implemented_unverified`。最新构建必须在用户指定的原始游戏路径、同一启动会话中
完成以下 E2E，才能升级声明：

```text
process/helper/IPC identity
  → TextRender geometry
  → submit hit
  → Fushi 本地查词与 galCard 离屏布局
  → BGRA frame published
  → BufferRouteReady + FramePresented
  → 游戏画面内只有一张完整 Fushi popup
  → 顶部整句横幅不显示、命中词高亮正确
  → popup 内交互/制卡可用
  → Esc/换行正确消场
```

真实会话还必须确认桌面上没有第二张 popup；否则不能把“游戏内有卡”写成通过。

## 11. 主要实现位置

| 层 | 文件 |
|---|---|
| v14 wire ABI / 帧校验 | `native/galgame_hook/include/voice_hook_ipc.h` |
| KiriKiri 几何、输入、高亮与位图 Layer | `native/galgame_hook/hook/adapters/kirikiri_adapter.inc` |
| Windows 读写/截帧/MethodChannel | `fushi/windows/runner/voice_hook_reader.{h,cpp}` |
| 离屏 popup 窗口 | `fushi/windows/runner/global_lookup_window.{h,cpp}` |
| Dart channel | `fushi/lib/src/platform/gal_hook_text_overlay_channel.dart` |
| 查词与 popup 编排 | `fushi/lib/src/lookup/gal_ingame_lookup_controller.dart` |

IPC 两侧必须在同一 PR 中落地。后续能力继续复用 Fushi popup 与 v14 BGRA 帧契约，不能再引入一条
NativeText/TJS 手绘平行主路。
