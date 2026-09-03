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
- **[x] ① 已修复** — 本分支（`worktree-popup-render-tail`）；提交 `3c71c13575`（第一批）
  + `047614e023`（第二批）+ 合 develop 后的前置补齐（本条 PR 的合并提交）：masonry 三相批处理 + 脏 body
  集合、尾批 MessageChannel + 时间预算分片、CSS memo LRU（256 桶）；第二批（同分支）：
  每本词典一份 `<style>`（原每块一份）、尾批在途不回报高度（原逐帧回报 = 宿主逐帧重定尺）、
  ResizeObserver 高度未变不重铺、renderPopup 换代断开旧 observer（热槽跨查词攒已摘除卡片
  的强引用）、**嵌套层 WebView 键停驻与接管**（原每次嵌套查词冷建 WebView）、in-app 主题
  变量注入收成单一真相源（原第二份拷贝缺 eink / 卡底色 RGB）
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_render_tail_batching_test.{js,dart}`（新，
  node 真执行 popup.js，4 条变异各红；第二批加 ⑤⑥⑦ 三条、5 条变异各红）、
  `fushi/test/dictionary/popup_render_signal_guard_test.dart`
  （尾批原语改锚 + 新增 ⑤ 宏任务原语守卫）、`fushi/test/utils/misc/popup_dict_css_memo_test.{js,dart}`
  （④ 改 LRU 语义：反复命中的桶不得被淘汰）、`fushi/integration_test/popup_render_tail_perf_itest.dart`
  （新，Windows 离屏计时；**绝对耗时不做断言**，但补了三条不依赖机器的形态不变式：
  块数守恒、样式表数 < 块数、尾批宏任务数 < 块数。它**不在任何 runner 清单里**——
  `ci/integration-test.sh` 的 `ALL_TARGETS` 只解析 `<target>_test.dart`，本目录 45 个
  `_itest.dart` 一律只经 `tool/run_windows_itest.ps1` 手动跑）、`fushi/test/pages/dictionary_popup_controller_test.dart`
  （新组「嵌套 realm 停驻与接管」5 条）、`fushi/integration_test/popup_dictionary_test.dart`
  （新 Phase 5：真 WebView2 上嵌套→关→再嵌套断言接管同一 WebView State）
- **备注**：查词 FFI 挪独立 isolate **判定不做**——真实词典实测引擎段首查 0～6ms、复查 0～3ms
  （见下「引擎段实测」），收益为零而阻塞三处（同步分词 API 的 7 个同步调用点、删词典前的
  mmap 释放跨 isolate 时序、`FushiDicts.dictionaryStyles` map 身份记忆化契约）。

### 现象与量级（Windows 离屏实测，`tool/run_windows_itest.ps1`，真 WebView2 + 真 popup.js，不启动 app）

itest 把 popup.css / dict-media.js / selection.js / popup.js 按生产 Windows 弹窗同款
`initialData` 内联，灌合成词条（结构化释义高度参差），`--dict-columns: 2`，钩住
`requestAnimationFrame` / `HTMLElement.prototype.offsetHeight` / `popupRendered` 计数。
每场景跑两轮取第二轮（热 JIT / CSS memo）。⚠️ **下表是作者本机的单次采样**：没有第二台
机器复核，CI 也从不跑这个 itest（见上条 ②）。绝对数字只用来说明量级与趋势，不是回归门；
真正会红的是那三条不依赖机器的比值不变式。

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

### 第二批（用户「还有没有能再优化的」→「全部根本性实现、修复」）

itest 加了分段计时（尾批宏任务 / masonry 各自墙钟、`<style>` 元素数、宿主收到的高度
去重后个数）并给每本词典配了 24 条规则的自带 CSS（真实 Yomitan 词典包普遍如此）。热态：

| 场景 | complete | 尾批构建 | masonry | RAF 帧 | `<style>` 新建 | 高度回报（去重） |
|---|---|---|---|---|---|---|
| 10×5＝50 | 44 → **41 ms** | 20 → **14** | 15 → 18 | 5 → 5 | 50 → **0** | 7(6) → **4(3)** |
| 30×5＝150 | 194 → **129 ms** | 97 → **55** | 66 → 52 | 17 → 11 | 150 → **0** | 19(18) → **4(3)** |
| 3×12＝36 | 27 → **23 ms** | 11 → 11 | 9 → 6 | 4 → 2 | 36 → **0** | 6(4) → **3(3)** |

（`<style>` 列的 0 是第二轮：同名词典的样式节点第一轮已建好、之后只比对文本。）

5. **每个词典块一份 `<style>`**。词典样式的选择器本来就是 `[data-dictionary="名"]` 全局作用域，
   与它挂在哪个块里无关；每插一个样式表整个文档样式失效，下一次布局读（masonry 量高）就把
   全部卡片重算一遍。改 `ensureDictionaryStyle(dictName, text)`：按词典名去重、文本变了就地
   改 textContent、挂 head（扩展是 shadow root，插在 `style.fushi-custom-css` 之前，层叠顺序
   「基础 css < 词典样式 < 自定义 CSS」与旧位置等价）。
6. **尾批在途逐帧回报高度**。宿主每收一次就 `setState` + 重定尺平台视图一次——这才是「弹窗
   高度反复变」的本体。masonry 帧只在 `!window._renderInProgress` 时回报；宿主要的只有首词条
   高度（撤盖板）与全部建完的终高两个稳定值。150 块从 19 次回报降到 4 次。
7. **ResizeObserver 二次重铺**。masonry 写完列宽、量完高，RO 会在同一轮管线末尾再报一次
   （首次 observe 也必报）；高度与刚量到的 `__fushiMasonryHeight` 一致就不排帧。顺手修了
   renderPopup 换代不断开旧 observer 的泄漏：RO 强引用观察目标，热槽 WebView 跨成百上千次
   查词不重载，已摘除卡片子树一直攒在内存里。
8. **嵌套查词每层冷建 WebView**（`dictionary_popup_controller.dart`）。常驻热槽只服务第一层；
   嵌套层被裁掉即销毁，下一次嵌套再来一遍 ~300KB 内联 HTML/CSS/JS 解析 + 全量静态段重注入
   + 首次布局 JIT。现在 `_retireEntries` 把非热槽层的 `webViewKey` 停到 `parkedRealms`
   （上限 `kMaxParkedRealms=1`，低内存不停），六个宿主把每把键渲染成屏外隐藏层
   （`parkedRealmPopupLayer`），`beginTop` / `pushChild` 建非热槽层时 `_takeRealmKey()` 接管
   ——同一把 GlobalKey ⇒ Flutter 整体搬 element，不拆不建原生表面。停驻的是**键**不是
   entry：在途的旧查词握着旧 entry，`entries.contains` 恒假，绝不会把旧词结果灌进新层。
9. **in-app 主题变量第二份拷贝**。`dictionary_popup_webview._themeVariablesJs()` 每次查词
   都拼一份只为主题热切换去重，且比真源少 eink toggle 与 `--fushi-card-bg-rgb`；删掉，
   `PopupStaticSettingsJs` 带出 `themeVarsJs`，热切换重注同一段。

### 引擎段实测（判定「查词 FFI 挪独立 isolate」不做）

`lookup_latency_perf_itest.dart` + 真实词典（実用日本語表現辞典 Extended 9.4MB + Jiten
Novel 频率 4.6MB，`isolated-root/fixtures/perf-dicts/`）：`[perf-engine]` 首查 10 条
0～6ms、复查 0～3ms；`[perf-e2e]` 冷 13ms、复查 43～50ms（含 WebView 渲染）。引擎段不是
瓶颈；isolate 化要付端口往返 + 结果序列化，还要先解决同步分词 API 的 7 个同步调用点、
删词典前跨 isolate 释放 mmap、样式 map 身份记忆化三处阻塞。除非词典集把引擎段推到几十
毫秒以上，否则不值得。

### 未覆盖 / 未做

- 只在 **Windows WebView2** 实测；Android / iOS / 扩展浏览器同一份 popup.js，机制无平台分叉
  （MessageChannel / ResizeObserver / RAF 三者都是基线 API），但没有真机数字。
- 「显示」里用户感知的抖动本轮通过「高度回报次数 / 帧数」间接量化；Layout Instability API
  不计 transform 位移，`layoutShiftScore` 前后都 ≈0，不能作抖动证据（已在 itest 注释说明）。
- app 外全局查词窗 `global_lookup_host.js` 的 standby 池仍是 1：每次取用后双 rAF 即补货
  （≈ 一次 iframe 装载），只有两次嵌套间隔短于补货窗口才会吃到冷 realm，人手点词达不到；
  多停一个就多一份 realm 内存，没有测得的收益不加。
- 嵌套时 `entriesJs` 的重传随 realm 接管已经只发本层词条，不再需要反向回补通道。

### 设计代价（这批改动换来的新观感，不是 bug 但要写明）

`_renderInProgress` 门（尾批在途不回报高度）把「弹窗高度一帧一变」换成了**「先高后缩一次」**：
首词条渲染完之后、整个尾巴期间，宿主拿到的高度是 masonry 铺开之前那个**偏高的 grid 高度**，
直到收尾才一次性收缩到真实高度。也就是说抖动没有被消灭，是被**换成了一次幅度较大的收缩**。

这是刻意的取舍：一次可预期的收缩比 140 次逐帧重定尺好，但它是一种**新的**观感，
不是「和以前一样只是更快」。真要连这一次收缩也去掉，得让宿主在尾批期间按预估终高定尺
（需要一个尾批开始前就能算出的高度上界），那是另一件事，不在本条范围内。
