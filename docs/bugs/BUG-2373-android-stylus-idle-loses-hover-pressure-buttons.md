## BUG-2373 · 安卓平板触控笔闲置1-2分钟后悬停/压力/侧键全失效
- **报告**：2026-09-09（用户转述第三方报告者；**设备不在手，本地无法复现**）
- **现象**：安卓平板在 Hibiki 内使用触控笔，约 1~2 分钟不操作后，笔的悬停光标、压力感应、侧键**全部**失效；同一时刻手指触摸完全正常（点击、滑动均可）。唯一恢复方式是切后台（多任务界面）再切回前台，恢复后再次闲置又复发。系统自带笔记应用与其他第三方应用无此现象。报告者已关闭平板全局手势与电池优化，问题依旧。
- **真实性**：⏳ **未复现**（设备不在手）。三条独立代码路径排查后，**本仓不存在任何 1~2 分钟量级、会影响输入或窗口状态的逻辑**：
  - Android 原生层：全树无 `Timer` / `TimerTask` / `ScheduledExecutorService`；唯二 `postDelayed` 在独立 `:network_challenge` 进程；窗口 flag 创建后除亮度（`MainActivity.java:1089-1101`）与悬浮窗焦点开关（`FloatingDictService.java:164-172`）外从不变动；无 `onHoverEvent` / `onGenericMotionEvent` / `setPointerIcon` / `TOOL_TYPE_STYLUS` 任何实现（零匹配）。
  - Dart 层：最接近的空闲门是 `StudyClock`，默认 `kDefaultReadingIdleTimeout = 10 分钟`（`packages/fushi_audio/lib/src/audiobook/study_clock.dart:32`），且超时只做 `_seal()` 结算 DB 段落，不触碰窗口/焦点/WebView。全部 `SystemChrome.*` 调用均由页面进出、用户点击、内容就绪或 `resumed` 触发，无一由定时器触发。
  - WebView/JS 层：注入脚本无任何定时 `removeEventListener`，无定时改 `pointer-events`/`touch-action`/`cursor`，reader 内 30 秒~3 分钟量级定时逻辑零匹配。
  - **推论**：这个 1~2 分钟的节律不是本仓打的，来自系统侧（1~2 分钟正是常见屏幕超时/闲置降刷阈值）。

### 主假说（未证实）：`preferredDisplayModeId` 与系统闲置降刷策略打架
`HighRefreshRate.applyToActivity`（`MainActivity.java:155` 调用，实现 `HighRefreshRate.java:69-71`）在 `onCreate` 给窗口钉死
`WindowManager.LayoutParams.preferredDisplayModeId`，此后**永不重申、永不重置**（`onResume` 不调用它，`MainActivity.java:404-427`）。
引入于 2026-07-16 `9e6c588da0`（修"滚动帧率被锁 60Hz"），2026-07-18 `5993fdc369` 扩到弹窗/悬浮窗。
这是全 app 唯一一个非默认的、会干预系统显示调度的设置。

该假说逐条对上了全部五个观察：
| 观察 | 假说解释 |
|---|---|
| 闲置 1~2 分钟后失效 | 系统闲置降刷策略生效（多数平板 60~120 秒无输入后降档省电） |
| 笔的悬停/压力/侧键失效 | 多数平板笔数字化仪采样率与显示刷新率档位绑定，降档时笔扫描一并降级 |
| 手指触摸仍正常 | 触摸屏扫描独立于笔数字化仪，不随显示档位降级 |
| 切后台再回前台即恢复 | 窗口重新可见 → 系统重新应用 `preferredDisplayModeId` → 回到高刷 → 笔恢复 |
| **其他 app 无此问题** | 其他 app 不请求 `preferredDisplayModeId`，走系统正常自适应策略；只有钉死 mode 的窗口才会与降刷策略产生冲突状态 |

**这仍是假说，不是结论**：厂商笔扫描与显示档位是否真的绑定、系统降刷是否真会使钉死的 mode 进入冲突状态，均未经测量。

### 次假说（更弱）：`FLAG_KEEP_SCREEN_ON`
`reader_fushi_page.dart:2462` / `app_model.dart:5820` → `wakelock_plus-1.7.0/android/.../Wakelock.kt:28` `window.addFlags(FLAG_KEEP_SCREEN_ON)`。
其他应用屏幕会超时变暗迫使用户交互，Hibiki 让屏幕长亮而系统侧「用户已闲置」计时照走。
比主假说弱：它不解释「切后台再回来即恢复」（该 flag 不随生命周期增删）。

### 零门槛验证方法（报告者自己就能做，不需要 adb、不需要开发者在场）
1. **系统设置 → 开发者选项 → 打开「显示刷新率」浮层**（Show refresh rate），复现到笔失效那一刻看屏幕角上的数字：
   - 数字**掉档**（如 120→60 或 60→30）→ **主假说成立**，根因在 `HighRefreshRate`。
   - 数字**不变** → 主假说被证伪，转次假说与下面第 2、3 条。
2. 失效时**不要切后台**，改为旋转屏幕（触发 `onConfigurationChanged`，窗口重建但不离开 app）：恢复 → 问题在窗口层；不恢复 → 在进程/系统层。
3. 失效时下拉系统通知栏，笔在通知栏区域悬停：通知栏也失效 = 系统级停了笔扫描；仅 app 内失效 = 本窗口问题。
4. 关闭阅读器「保持屏幕常亮」后复现 → 验次假说。
5. 停在**设置页**（纯 Flutter，无 WebView）而非阅读器页是否同样失效 → 切开 WebView 责任。
6. 平板品牌型号 + 系统版本（S Pen / 华为 M-Pencil / 小米灵感笔的悬停与侧键实现各不相同）。

### 为什么现在不动代码
主假说指向 `HighRefreshRate`，但**没有任何测量证据**。在零证据下改它（换 `preferredRefreshRate`、或在 `onResume` 重申）有两个问题：
一是无法验证改动是否真的修好了本条；二是会破坏它 2026-07-16 原本修好的「滚动帧率被锁 60Hz」（Never break userspace）。
等第 1 条验证结果回来再动。

### 顺带发现的既有缺口（独立立项，与本条互不阻塞）
**本 app 对 stylus hover 的支持本就缺失**：`fushi/lib/src/focus/fushi_focus_target.dart:209`、`fushi/lib/src/utils/misc/platform_utils.dart:301`、`dictionary_popup_layer.dart:984`、`video_fushi/controls_visibility.part.dart:74` 的 hover 逻辑一律 `kind != PointerDeviceKind.mouse → return`，把 stylus 排除；阅读器注入 JS 只监听 `mousemove`（`reader_fushi/webview.part.dart:1505`），无 `pointerover`/`pointerenter`，全仓无 `pointerType === 'pen'` 分支；侧键唯一通道是 `webview.part.dart:1371` 的 `mousedown` 非左键分支。这不解释「先能用后失效」，但会让笔在 Hibiki 内的体验本就弱于系统笔记应用。

- **[ ] ① 未修复** — 根因未定位，等「显示刷新率浮层」验证结果。
- **[ ] ② 未加自动化测试** —
- **备注**：设备不在开发者手上，本地无复现条件。三路排查（Android 原生 / Dart 生命周期 / WebView+JS）均为负面证据，已逐条记录以免后续重复挖掘。
