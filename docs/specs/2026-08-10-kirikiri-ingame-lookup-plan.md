# KiriKiri/KAGEX 游戏内查词实现计划

> 状态：待评审。取代 Draft PR #799 的实现路线，**保留** #799 的 Hook 边界发现。
> 平台边界：**仅 Windows**（galgame 硬规则，见 [CLAUDE.md](../../CLAUDE.md)）。
> SOP：[docs/agent/galgame-hooking.md](../agent/galgame-hooking.md)。

## 0. 一句话

把 #799 的「TJS 里手写整条查词链路」改成 **「TJS 只做几何传感 + 输入转发，Hibiki 出像素，游戏只负责显示」**。

## 1. 既有事实

### 1.1 样本身份

| 项 | 值 |
|---|---|
| 游戏 | Limelight「天使☆騒々」系（`tenshi_sz.exe`） |
| 引擎 | KiriKiri Z + KAGEX，第三方 `textrender.dll` 排版 |
| 架构 | exe 与全部 38 个 plugin DLL **均为 x86** |
| 关键 module | `textrender.dll`（SHA-256 `44D7B056…64EE70`）、`msdfrender.dll`、`kagexopt.dll`、`KAGParserEx.dll`、`DrawDeviceD2D.dll` |
| 完整性校验 | 每个资产带 `.sig`，另有 `ファイル破損チェックツール.exe` |

`.sig` 是**磁盘文件**校验，不校验内存。故硬约束：**绝不修改游戏目录下任何文件**（含不往游戏目录写临时文件）。

### 1.2 #799 里值钱的部分（保留）

运行日志已证伪 `MessageLayer.processCh` / `Layer.drawText` / `msdfrender.dll!drawGlyph` 三条路径。唯一命中的边界是：

```text
TextRender.render / done  →  renderer.getCharacters(0, 0)  →  逐字符 text/x/y/cw/size
TextRender.drawCh(layer, ox, oy, ch)  →  补齐 layer 与绘制原点
```

外加经 `iTVPFunctionExporter` 查询官方 ABI、用 `TVPAddContinuousEventHook` 延到游戏主线程执行 bootstrap 的时序模型。**这两件是本次唯一不可替代的发现，全部保留。**

### 1.3 Hibiki 已有、可直接复用的能力

| 能力 | 位置 |
|---|---|
| WebView2 **离屏合成** + `SendMouseInput` 输入注入 | `fushi/windows/runner/global_lookup_window.cpp:1089` `:1154` `:2150` |
| Yomitan 同级词典卡片（ruby / 外字图 / 发音 / 制卡 / 主题 / 17 语言） | `fushi/assets/popup/popup.html` |
| 查词分发、去屈折、假名复合词选择、词典优先级 | `fushi/lib/src/lookup/desktop_lookup_dispatcher.dart`、`sentence_extraction.dart` |
| hook↔host 共享内存 IPC（含 host→hook 控制字段先例 `selected_text_thread_id`） | `native/galgame_hook/include/voice_hook_ipc.h:296` |
| host 侧共享内存读取器 | `fushi/windows/runner/voice_hook_reader.cpp` |
| galgame 会话 / 制卡 / 语音配对 | `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart` |

## 2. 决策

**用户已拍板：能在游戏内渲染就在游戏内渲染**（体验显著优于游戏外浮窗）。

由此确定：

- ✅ 卡片是游戏渲染树里的真 `Layer`：不抢焦点、不 alt-tab、跟随全屏与窗口变换。
- ✅ 「独占全屏盖不住外部窗口」这个风险直接消失，不再需要为它做前置测量。
- ❌ 但**不等于**在 TJS 里手写卡片。卡片显示在哪，与「谁做分词、查词、排版」是正交的两件事；#799 把它们焊死了。

## 3. 目标 / 非目标

### 目标

1. 在游戏内点击/悬停字幕字符 → 游戏内出现与 Hibiki 自身**像素一致**的词典卡片。
2. 注入进游戏进程的代码只做：几何采集、命中测试、位图显示、输入转发。
3. 游戏进程内**没有** HTTP 客户端、没有认证 token、没有 JSON 解析器、没有动态字符串 eval。
4. 卡片能力（ruby / 外字 / 发音 / 制卡 / 主题 / 语言 / 字号）与阅读器、视频、剪贴板查词**同一份实现**，不产生第二套。

### 非目标

- 不做 Android / iOS / macOS / Linux。
- 不宣称「支持 KiriKiri」——只对本样本的 `textrender.dll` 组合有证据。
- 不做形态素分析：host 现有分词就是真值。
- ruby / 竖排 / 选项文字 / 名字栏：P1 之后单独排期。

## 4. 架构

### 4.1 三段职责

```text
┌─ 游戏进程 ────────────────────────────────┐      ┌─ Hibiki ─────────────────┐
│ TJS 传感器                                 │      │                          │
│   TextRender.render/done → 字符几何        │      │                          │
│   drawCh → 绑定 layer + 原点               │      │                          │
│   KAG hook → 命中测试 / 输入转发           │      │                          │
│        │ hit(整行文本, 字符下标, 字形矩形)  │      │                          │
│        ├──────────── 共享内存 ────────────────────▶ DesktopLookupDispatcher  │
│                                            │      │        ↓                 │
│ hook DLL                                   │      │ popup.html @ WebView2    │
│   memcpy BGRA → Layer 像素缓冲             │      │ 离屏合成 → BGRA 位图      │
│   TVPExecuteScript("…Apply(seq,s,len);")   │◀─────────────── 共享内存         │
│        │ 只含整数                          │      │                          │
│ 游戏渲染树里的卡片 Layer + 字幕高亮         │      │                          │
└────────────────────────────────────────────┘      └──────────────────────────┘
```

**关键性质**：跨边界的东西只有「一块位图」和「一串整数」。字符串 eval 的注入面**从结构上消失**，不是靠 escape 得更严。

### 4.2 IPC 契约（`voice_hook_ipc.h`，`kSharedVersion` 13 → 14）

`SharedHeader` 新增：

```c
// ── v14 游戏内查词区（injector 填偏移/容量）────────────────────────────
uint32_t lookup_region_offset;         // 查词区起始（header 起算字节偏移）
uint32_t lookup_bitmap_capacity;       // 单帧位图字节上限
volatile uint64_t lookup_hit_count;    // hook→host 单调：命中事件数
volatile uint64_t lookup_frame_count;  // host→hook 单调：已投位图帧数
volatile uint64_t lookup_input_count;  // hook→host 单调：转发的卡片输入事件数
volatile uint32_t lookup_enabled;      // host→hook：1=开启（取代 #799 的环境变量开关）
uint32_t lookup_reserved;
```

区布局：`[LookupHitSlot][LookupInputSlot 环][LookupFrame 双缓冲 + BGRA 字节]`

```c
struct LookupHitSlot {          // hook→host，单槽 latest-wins
  volatile uint64_t seq;        // 单调；host 据此判新
  uint32_t char_index;          // 光标落在第几个字符（UTF-16 code unit 下标）
  uint32_t char_count;          // 本行字符数（自洽校验）
  uint32_t glyph_x, glyph_y, glyph_w, glyph_h;  // 命中字形矩形（primaryLayer 坐标）
  uint32_t view_w, view_h;      // primaryLayer 尺寸 → host 据此定位与钳制卡片
  uint32_t line_bytes;
  uint8_t  line_utf8[kLookupLineBytes];  // **整行**，不截断（制卡要整句）
};

struct LookupFrame {            // host→hook，双缓冲
  volatile uint64_t seq;        // 对应哪次 hit；过期帧由 hook 丢弃
  uint32_t width, height, pitch;      // BGRA，预乘 alpha
  uint32_t anchor_x, anchor_y;        // 卡片左上角（primaryLayer 坐标，host 决定）
  uint32_t highlight_start, highlight_len;  // 字幕高亮范围
  volatile uint32_t ready;      // 0=写入中，1=可读
};

struct LookupInputSlot {        // hook→host 环，转发落在卡片矩形内的输入
  uint64_t seq; int32_t x, y; uint32_t kind; int32_t wheel; uint32_t keys;
};
```

设计要点：

- **卡片定位在 host**：hook 只报字形矩形与视口尺寸，host 复用它给 popup 已有的「避让 + 钳制」逻辑。不在 TJS 里重算一遍。
- **整行不截断**：#799 从点击字向后截 48 字（`kirikiri_adapter.inc:878`），制卡拿不到完整句子。
- `lookup_enabled` 是 host→hook 控制字段，形态照抄已有的 `selected_text_thread_id`。**#799 的 `FUSHI_KIRIKIRI_LOOKUP_PORT/TOKEN` 环境变量全部删除**——token 明文躺在游戏进程环境块里是安全缺陷。
- 契约两侧必须同 PR 落地（CLAUDE.md 硬规则）。

### 4.3 像素落地路径

**主路**：`Layer.mainImageBufferForWrite` + `Layer.mainImageBufferPitch`（KiriKiri Z 给插件写像素的标准出口）。DLL 经 exporter 的 `TVPExecuteExpression` 取回这两个整数 → `memcpy` → `TVPExecuteScript("global.fushiLookupApply(seq,start,len);")`。

**备路**：host 把卡片存 PNG 到 **`%TEMP%`（绝不写游戏目录）**，TJS `loadImages(路径)`。零新 ABI，代价是每次更新一轮 PNG 编解码（~10–20ms），够 P1 静态卡片，不够 P2 交互。

主备之间由 **P0 探针**的真机结果裁决，不靠猜。

## 5. 阶段与验收

### P0 — 地基探针（阻塞后续全部工作）

只往 #799 分支加一个 opt-in 探测开关，不动主逻辑。回答四个问题，输出结构化结果：

1. `TVPExecuteExpression`（`void ::TVPExecuteExpression(const ttstr &,tTJSVariant *)`）能否按 narrow string 从 exporter 查到？
2. x86 下 `tTJSVariant` 的整数读取布局是否正确？
3. `mainImageBufferForWrite` / `mainImageBufferPitch` 是否返回合法写指针与 stride？
4. `memcpy` 一张纯色测试位图 + `update()` 后，**屏幕上真出现色块**（真机目视 + 截图取证）。

**四问全绿 → 走主路；任一红 → P1 改走 PNG 备路，架构不变。**

验收：真机截图 + 探针结构化输出；结果写回本文件。

### P1 — 静态卡片

- TJS 传感器瘦身：**只留 TextRender 一条捕获路径**，其余四条移入默认关闭的 probe 模式。
- 建卡片 `Layer`（`ltAlpha`）+ 字幕高亮 Layer，生命周期绑定到 `seq`。
- DLL：hit 上报 / 帧落地 / 整数脚本回执。
- host：`voice_hook_reader.cpp` 读 hit → Dart → `DesktopLookupDispatcher` → 离屏 WebView2 → `CapturePreview` 取帧 → 回投。
- 键盘动作走 KAG `keyDown` hook：制卡 / 发音 / 关闭。

验收：真机点击字幕 → 游戏内出现与 Hibiki popup 像素一致的卡片；卡片随 `[cm]`/换页正确消失；连点不串卡（`seq` 过期帧被丢弃）。

### P2 — 交互式卡片

- 光标落在卡片矩形内时，TJS 转发 `(x-anchor_x, y-anchor_y, button, wheel)` → host → **已有的** `SendMouseInput` → 新帧回投。
- 帧率不够时把 `CapturePreview` 换成自持 `CreateSwapChainForComposition` + `CopyResource` 到 staging 纹理。

验收：卡片内滚动、展开词条、点发音按钮均生效；游戏帧率无肉眼可见回退。

### P3 — 制卡 E2E

按 SOP 完成「当前台词 → 对应语音 → 当前画面 → 真卡写入」，再更新 `engine-support.yaml`。**在此之前一律 `implemented_unverified`。**

## 6. 必须一并清掉的 #799 债务

游戏内渲染意味着我们在游戏主线程上花的每一毫秒都直接变成掉帧，这些比之前更要命：

| 位置（#799 版 `kirikiri_adapter.inc`） | 问题 |
|---|---|
| `:1367-1371` | `System.addContinuousHandler` **每帧**遍历所有 message 重打补丁 |
| `:1554-1558` + `:830` | 每次 mousemove 全量 walk + 对 primaryLayer 尺寸的 layer 做全屏 `fillRect` |
| `:993-998` | O(n²) `getTextWidth`，且挂在**全局** `Layer.drawText` 上，影响游戏所有 UI 绘制 |
| `:1128` `:1131` | `fushiLookupTextRenderRegistry` 只增不减，且持有 `characters` 数组与 renderer 引用 → 泄漏 |
| `:1550` | 每次左键往磁盘写 `.trace` 文件 |
| `:1827` `:1929` | 硬编码只认 `Jitendex` + `maximumTerms:1`（预算单位错配的老形状） |
| `:915-916` | 卡片固定 30 字/行 × 7 行 |
| `:1905` `:1909` | DLL 内 WinHTTP + token 落游戏进程环境变量 |
| `:1717-1836` | DLL 内手写 JSON 解析器 |
| `:1970` | 拼 TJS 源码字符串再 eval |

`:915` 起的卡片绘制、`:1717` 起的 JSON、`:1905` 起的 HTTP、`:878` 的分词——**整段删除**，由 host 侧既有实现承担。

## 7. 影响范围与风险点

| 风险 | 判断 |
|---|---|
| Magpie 超分会把卡片**连同游戏画面一起放大** | 「在渲染树内部」的必然结果，不是 bug。接受，或这局关超分。**不设计规避**——规避手段恰好推翻需求。 |
| `mainImageBufferForWrite` 触发 copy-on-write；layer 尺寸变化后指针失效 | 每帧重取，不缓存指针 |
| 主线程 memcpy 位图（700×400×4 ≈ 1.1MB） | ~0.1ms 量级，可接受；`CapturePreview` 在 host 线程，不阻塞游戏 |
| `kSharedVersion` 13→14，host/hook 版本漂移 | 两侧必须同 PR 落地；reader 侧对旧版本降级为「查词区不可用」而非崩 |
| 文件完整性校验 | 只注入、不改磁盘文件，`.sig` 不受影响；备路 PNG 写 `%TEMP%` |
| 泛化过度 | profile 以 `textrender.dll` 存在 + `global.TextRender.getCharacters` 运行时探测双重为门；缺失即退回现有浮窗查词 |

受影响的既有功能：galgame 文本捕获 / 语音配对 / 会话统计（共享内存布局变更）、`voice_hook_reader.cpp`、injector 的区分配。均为**追加**，不改动既有区偏移语义。

## 8. 验证门

native（在 `native/galgame_hook/`）：

```powershell
python tools/generate_engine_support.py --check
python tools/generate_luna_profiles.py --check
python tests/engine_support_manifest_test.py
python tests/adapter_structure_test.py
python tests/galhook_workflow_test.py
cmake -S . -B build-x86 -A Win32 ; cmake --build build-x86 --config Release
ctest --test-dir build-x86 -C Release --output-on-failure
cmake -S . -B build-x64 -A x64  ; cmake --build build-x64 --config Release
ctest --test-dir build-x64 -C Release --output-on-failure
```

新增测试（**在最强可落地层**）：

- **replay fixture**：`hit → frame → apply` 时序；`seq` 过期帧被丢弃；`lookup_enabled=0` 时零写入；卡片外的输入不进转发环。
- **源码扫描守卫**：`kirikiri_adapter.inc` 里 `TVPExecuteScript` 的实参不得由动态字符串拼接（只允许 `std::to_wstring` 的整数）。守卫必须做**变异实测**——把断言字面量塞进注释验证它真会红。
- **Dart**：hit 事件 → dispatcher → 位图投递的单测。

Fushi 侧：`dart format` 改动文件 + 定向 `flutter test --no-pub`；合入 develop 前全量 `dart run tool/flutter_test_failures.dart --no-pub`（**只认末行 verdict + 退出码**），外加合并后必跑的目录枚举型守卫整批。

## 9. 不做什么

- 不保留 #799 的 5 条并行捕获路径与 3 个 registry 兜底链——实测只有 TextRender 命中，其余是调试残骸。
- 不在游戏进程里保留任何网络客户端或认证凭据。
- 不为「独占全屏」保留一套平行的游戏外 UI。
- 不动 `engine-support.yaml` 的支持状态，直到 P3 E2E 完成。
