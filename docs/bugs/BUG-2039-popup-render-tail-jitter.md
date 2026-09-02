## BUG-2039 · 查词弹窗渲染尾巴逐帧掉块、卡片跳位、高度反复变
- **报告**：2026-09-02（用户：「优化一下查词弹窗的速度和显示」→ 确认「显示」= 渲染尾巴的视觉抖动）
- **真实性**：✅ 真 bug。BUG-1868（PR #1014）把「每次查词重传 33.7MB 内联字体」修掉后，
  剩下的慢与抖全在 popup.js 首词条之后的**渲染尾巴**：一块一帧、每帧全量重铺、每张卡片
  一次强制回流、每帧一次跨进程高度回报。根因 `fushi/assets/popup/popup.js`：
  - `renderNextDictionaryBlock` 一块一个 `setTimeout(fn, 0)`（旧 :4774/4780）；
  - `appendNextDeferredGlossaryBlock` 每追加一块 `scheduleMasonry()`（旧 :3902）→ RAF 里
    `layoutMasonry()` 对**所有** body 全量重铺（旧 :4396）；
  - `layoutMasonry` 每张卡片「写 6 个样式 → 读 `offsetHeight`」（旧 :4437-4445）；
  - `dict-media.js:43` `__dictCssCache` 满 64 桶整表 `clear()`。
- **[x] ① 已修复** — 本分支（`worktree-popup-render-tail`）：masonry 三相批处理 + 脏 body
  集合、尾批 MessageChannel + 时间预算分片、CSS memo LRU（256 桶）
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_render_tail_batching_test.{js,dart}`（新，
  node 真执行 popup.js，4 条变异各红）、`fushi/test/dictionary/popup_render_signal_guard_test.dart`
  （尾批原语改锚 + 新增 ⑤ 宏任务原语守卫）、`fushi/test/utils/misc/popup_dict_css_memo_test.{js,dart}`
  （④ 改 LRU 语义：反复命中的桶不得被淘汰）、`fushi/integration_test/popup_render_tail_perf_itest.dart`
  （新，Windows 离屏计时，不做性能断言）
- **备注**：

### 现象与量级（Windows 离屏实测，`tool/run_windows_itest.ps1`，真 WebView2 + 真 popup.js，不启动 app）

itest 把 popup.css / dict-media.js / selection.js / popup.js 按生产 Windows 弹窗同款
`initialData` 内联，灌合成词条（结构化释义高度参差），`--dict-columns: 2`，钩住
`requestAnimationFrame` / `HTMLElement.prototype.offsetHeight` / `popupRendered` 计数。
每场景跑两轮取第二轮（热 JIT / CSS memo）：

| 场景（词条×词典＝块） | complete | RAF 帧 | offsetHeight 读 | popupRendered 回报 |
|---|---|---|---|---|
| 10×5＝50 | 258 → **60 ms** | 39 → **6** | 1136 → **189** | 41 → **8** |
| 30×5＝150 | 959 → **259 ms** | 138 → **21** | 10895 → **590** | 140 → **23** |
| 3×12＝36 | 190 → **44 ms** | 29 → **5** | 601 → **131** | 31 → **7** |

三个场景改前改后最终 `scrollHeight`（7109 / 22228 / 4720）与卡片数逐字节一致，`hiddenCards=0`
——最终布局没变，只是过程变了。读次数从「随块数平方增长」（50→150 块：1136→10895，9.6×）
变成线性（189→590，3.1×）。证据：`fushi/.codex-test/windows-itest/render-tail-{base,after}/command.log`
（本地，不入库）。

「视觉抖动」的直接来源就是最后一列：改前 150 块的尾巴里宿主收到 140 次高度回报、每次
重定尺弹窗，用户看到的是弹窗高度一帧一变、卡片逐帧落位。

### 四条根因与修法（全在 popup.js / dict-media.js，不改 DOM 结构、CSS、Dart 契约）

1. **一块一宏任务 + setTimeout 嵌套钳制**。HTML 规范把嵌套 >5 层的 timer 钳到最短 4ms，50 块
   光排队 ≥200ms；且每块独占一帧。改 `scheduleRenderTail(task)`：MessageChannel 宏任务
   （无嵌套钳制、仍让出主线程给渲染/输入，React scheduler 同款），无 MessageChannel 的壳回落
   `setTimeout(task, 0)`；`renderNextDictionaryBlock` 改成 `do…while` 时间预算分片
   （`TAIL_SLICE_BUDGET_MS = 6`），一个宏任务连续建块直到预算用尽。逐块的抛错回滚 / 收尾
   语义不变（catch 内 return 结束整条链）。

2. **每追加一块就全量重铺**。新增 `masonryDirtyBodies` + `masonryDirtyAll`：`appendNext…`
   只 `markMasonryDirty(state.body)`；ResizeObserver 回调按 `entry.target` 找所属 body 标脏；
   `<details>` toggle 同理；resize / `fushiRelayoutDictionaries` / 无标脏的 `scheduleMasonry()`
   走全量（`scheduleMasonryAll`）。同一帧内「先标脏 A 再来一个 All」必须铺全部（测试锁定），
   帧跑完脏集合清空，`__fushiPrepareRealmForReuse` 同步清。

3. **每卡一次强制同步布局**。`layoutMasonry(targetBodies)` 改四相：读全部 `clientWidth` →
   写定位/列宽（同值不写，`setStyleIfChanged`）→ 一次读全部 `offsetHeight` → 写 transform /
   容器高。整轮两次强制布局，与卡片数无关。最短列打包、粘着列、单列/空 body 回落逐字不变
   （`popup_dict_masonry_guard_test.dart` 全部锚点仍命中）。

4. **CSS memo 满桶整表清空**。一次查词按「词条 × 词典」轮询全部词典 css，桶数 < 词典数时
   LRU 与 clear 同样逐次全 miss（循环访问），所以上限从 64 提到 256（明显大于任何真实词典集）；
   淘汰改 LRU（Map 插入序，命中即挪到队尾）只为换词典集时先清最久没用的。三份
   dict-media.js（app + 扩展两镜像，扩展侧有 image:// 分叉，故逐份手改）同步。

### 守卫改动说明

- `popup_render_signal_guard_test.dart` 原本用字面 `setTimeout(renderNextDictionaryBlock, 0)`
  锁「尾批必须是宏任务」。原语换成 `scheduleRenderTail(renderNextDictionaryBlock)` 后按语义
  等价改锚，并新增 ⑤：原语体内必须有 `postMessage(` + `setTimeout(task, 0)` 回落、不得
  `queueMicrotask`、文件里必须有 `TAIL_SLICE_BUDGET_MS`。
- `popup_dict_css_memo_test.dart` 原本钉 `__dictCssCache.clear()` 当「有界」证据，改为钉
  `size >= MaxBuckets` + `delete(keys().next().value)` 且断言 **不再** 有 `clear()`。

### 变异实测（新守卫 `popup_render_tail_batching_test.js`，改完 sha 校验还原）

| 变异 | 结果 |
|---|---|
| 相 2 写宽度后立刻 `void item.offsetHeight`（回到逐卡读） | ① 红 |
| RAF 回调改回 `layoutMasonry()` 无参全量 | ② 红 |
| 分片 while 条件改 `false`（一块一任务） | ③ 红 |
| `scheduleRenderTail` 无视 MessageChannel 恒 setTimeout | ④ 红 |

### 未覆盖 / 未做

- 只在 **Windows WebView2** 实测；Android / iOS / 扩展浏览器同一份 popup.js，机制无平台分叉
  （MessageChannel / ResizeObserver / RAF 三者都是基线 API），但没有真机数字。
- 「显示」里用户感知的抖动本轮通过「高度回报次数 / 帧数」间接量化；Layout Instability API
  不计 transform 位移，`layoutShiftScore` 前后都 ≈0，不能作抖动证据（已在 itest 注释说明）。
- BUG-1868 档案里其余「尚未处理」项（嵌套 `entriesJs` 全栈重传、standby 池=1、查词 FFI 主
  isolate）本轮不动。
