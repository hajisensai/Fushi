# 视频小窗模式 + 控件密度 + 底部细进度条（2026-09-22）

> 需求来自群内讨论：「给视频功能添加个无边框小窗功能吧，看着精致点」→「看 b 站的小窗口，
> 也可以根据窗口大小缩小一些那些进度条」→「手机咋办」→「添加一个开关把进度条缩小到
> 视频最下方用主题色」。参考图三张：B 站网页小窗（视频浮窗 + 分离侧栏）、iOS 画中画
> （无边框圆角 + 大号居中控件 + 底部细进度条）、B 站网页播放器控制条隐藏后底部那条细线。

## 交付物

三件事，共用一套判据：

1. **控件密度**：控制条按**播放区宽度**分三档（full / compact / mini），越窄越紧凑。
2. **小窗模式**：桌面把主窗变成无边框置顶小窗；Android 进系统画中画；iOS 不提供。
3. **底部细进度条**：独立开关（默认关），控制条淡出后在视频最下方留一条主题色细线。

## 判据真相源：`lib/src/media/video/video_controls_density.dart`

纯函数 + 纯值对象，页面只消费结论，阈值不散落在 widget 树里。

```dart
enum VideoMiniSurface { none, desktopMiniWindow, pictureInPicture }
enum VideoControlsDensity { full, compact, mini }

VideoControlsDensitySpec resolveVideoControlsDensity({
  required Size playerSize,
  required VideoMiniSurface surface,
});

bool videoSlimProgressBarVisible({
  required VideoControlsDensitySpec spec,
  required VideoMiniSurface surface,
  required bool preferenceEnabled,
  required bool controlsVisible,
});
```

### 为什么只看宽度，不看高度

视频页在手机上**全程强制横屏**，典型 844×390、最窄的 iPhone SE 横屏 568×320。任何
「高度 < N 就算小窗」的判据都会把正常手机播放判成 mini、把控件凭空缩掉一圈——纯回归。
宽度判据下手机横屏落在 full / compact，mini 只有真·小窗或被拖到 480 逻辑像素以下的
桌面窗口才够得着（桌面主窗常规最小尺寸就是 360×480）。

| 档 | 触发 | scale | 进度条 | 顶栏 | 底栏 | 居中三键 |
|---|---|---|---|---|---|---|
| full | 宽 ≥ 800 | 1.0 | ✓ | ✓ | ✓ | — |
| compact | 480 ≤ 宽 < 800 | 0.88 | ✓ | ✓ | ✓ | — |
| mini | 宽 < 480 或桌面小窗 | 0.72 | — | — | — | ✓ |
| （系统画中画） | PiP 态 | 0.72 | — | — | — | — |

尺寸非有限 / ≤ 0（首帧前 constraints 未落定）退回 full，绝不在测量未就绪时闪一下
小窗形态。

### 两种小窗的 chrome 归属相反

桌面小窗里窗口是空的、chrome 得本仓自己画；系统画中画里 Android 会在窗口上叠**自己的**
播放控件，本仓再画一套就是两层按钮重影。判据收敛在 `VideoMiniSurface.systemOwnsChrome`
一处，消费端不各自写 `Platform.isAndroid`。

## 密度怎么接进控制条

控制条是 vendored media_kit fork 的 `MaterialVideoControls`，本仓只喂 `*ThemeData`。

- 密度在 **`_buildVideoControls` 的 `LayoutBuilder` 里**算一次并存进
  `_activeControlsDensity`。整棵 controls 子树都建在那个回调里，所以 theme、字幕避让
  reserve、细进度条读到的是**同一帧同一个值**，不存在「theme 已经缩了、字幕还按旧几何
  让位」的跨帧错位。
- 尺寸 getter（`_videoButtonBarHeight` 等）**保持原样不动**（它们的语义是
  「基线 × 界面大小」，且被一批源码守卫逐字钉死），密度只在 theme 构造处与字幕避让
  两处显式相乘 `_controlsDensityScale`。刻意不折进 `_videoUiScale`：那个 getter 还被
  设置面板 / popover / 剧集面板消费，把「窗口有多小」混进去会让设置面板也跟着窗口缩。
- mini 档用 fork 里**一直存在却从未被本仓设过**的 `displaySeekBar: false` 收掉整条进度条；
  顶/底栏用 collection-`if` 整段不渲染。
- 字幕避让同步：`seekBarContainerHeight` 在 mini 档传 0（不为一条根本没画出来的进度条
  让出三四十像素），顶栏隐藏时 `buttonBarHeight` 传 0。

## 小窗模式

### 桌面：主窗变身（`lib/src/platform/desktop/desktop_mini_window_mode.dart`）

原生标题栏**本来就是隐藏的**（`main()` 里 `TitleBarStyle.hidden` + 自绘
`FushiDesktopTitleBar`），所以「无边框」只差把自绘顶栏也收起来。进入顺序：

记住当前外框 → 暂停几何记忆 → 下探最小尺寸（360×480 → 240×135）→ 摆到工作区右下角
→ 置顶 + `clearTaskbarFlash()` → 隐藏自绘顶栏 → 锁宽高比。退出按逆序还原。

几个必须处理的坑：

- **几何记忆污染**：`DesktopWindowPlacement` 会把窗口外框去抖存进 SharedPreferences。
  小窗几何一旦写进去，下次启动主窗就是个小窗。新增 `setGeometryMemorySuspended`
  闸门，与既有的「全屏态不存几何」豁免同一条纪律。
- **最小尺寸**：常规下限 360×480 由 `setMinimumSize` 下发，小窗必须临时下探，退出还原。
- **置顶的副作用**：`setAlwaysOnTop` 在前台锁定下会退化触发 `SetForegroundWindow`，
  把任务栏按钮设成闪烁请求注意态；仓里已有 `clearTaskbarFlash()` 专门善后，置顶后必调。
- **与全屏互斥**：进小窗前先退全屏（窗口侧全屏路由 + OS 原生全屏两条都退）。
- **退页必还原**：页面没了、窗口还是个无边框置顶小窗的话，用户就只剩任务管理器可用。
- **换集**：`updateAspectRatio` 连外框一起重算——`window_manager` 的 Windows 实现只在
  拖边框时（`WM_SIZING`）约束比例、不矫正当前尺寸，只下发比例会一直挂在上一集的框里留黑边。

### Android：系统画中画

manifest 里 `android:supportsPictureInPicture="true"` **早就声明了但从无任何调用**；
`android:configChanges` 也已含 PiP 需要的 `screenSize|smallestScreenSize|screenLayout|
orientation` 四项，无需改动。本次补上 `PictureInPictureChannelHandler`（Java）+ Dart 门面。

- 版本门：API 26+ 且 `hasSystemFeature(FEATURE_PICTURE_IN_PICTURE)`。
- 比例钳制：Android 只接受 `[1/2.39, 2.39]`，越界直接抛 `IllegalArgumentException`。
  **下端卡在四舍五入刀口上**——1/2.39 = 0.41841，按 1e-4 定点 round 成 0.4184 反而小于
  下界，照样抛；故分子用 `4185/10000` 与 `23899/10000` 各向区间内侧让一格。
- **进出状态只由回程写入**：系统可以在 app 完全没参与的情况下结束 PiP（用户点关闭、
  系统回收），`onPictureInPictureModeChanged` 是唯一的真相源。app 侧调 `enter` 只是
  发请求，不自说自话置位。
- PiP 态下本仓 chrome 全部让位（见上表），字幕 overlay 随密度缩小但继续渲染。

### iOS：不提供，且入口不出现

本仓画面是 libmpv 渲染进 Flutter texture 的，iOS 的 `AVPictureInPictureController` 只能
挂 `AVPlayerLayer` / `AVSampleBufferDisplayLayer`，拿不到这条纹理；桌面那套「把主窗变小」
在 iOS 也没有对应物。故 `_miniWindowAvailable` 在 iOS 恒 false——不给一个按下去没反应的
按钮。（这是技术限制，**不是** App Store 合规门控，与 `StoreRestrictedCapability` 无关。）

## mini 档自绘 chrome（对上参考图二）

`video_fushi/mini_window.part.dart`：

- **顶部拖动带**：32 逻辑像素，`DragToMoveArea` + 右端「退出小窗」钮。刻意只占顶部一条
  而不是整面——整面拖动会把「点画面暂停」和「点字幕查词」一起吃掉，而**字幕悬停制卡
  正是小窗要保住的能力**（`VideoSubtitleOverlay` 就在同一棵 Stack 里，零改动继续工作）。
- **居中大三键**：±10 秒 + 播放/暂停，圆形大钮。用的是与底栏同一个 10 秒常量、同一组
  对称图标。
- 两者都挂在共享的 `FadingChromeGate` 上（不可见时 `IgnorePointer` + `ExcludeFocus`，
  所以收起后一个指针都不吃，整幅画面继续交给字幕制卡）。

### 追加（同日用户反馈）：chrome 只认显式唤出，hover 不再唤起

> 「快捷键控制是控制里面那些图标进度条等的显示的，常态鼠标移到视频就显示一个字幕
> 可以来制卡就好，不然感觉太乱了。」

小窗是「挂在屏幕角落一直开着」的形态：鼠标从它上面**路过**就弹一层按钮，在 300×170 的
窗口里等于把画面盖掉一半。所以 chrome 的显隐从 `_videoControlsVisible`（media_kit 的
hover 语义）改挂一个独立的 `_miniChromeRevealed`，判据同样收进纯函数：

```dart
bool videoMiniChromeVisible({
  required VideoControlsDensitySpec spec,
  required bool revealed,
});
```

- **hover 不是它的输入**——这是本函数存在的全部意义。小窗常态 = 画面 + 字幕 + 底部细线。
- 唤出后**不自动淡出**：拖动带是无边框小窗唯一的窗口抓手，让它跟计时器赛跑等于拖不动。
- 唯一的自动显隐路径是**进小窗那次引导性亮相**（3 秒后自行收起）。不给这一下的话，第一次
  进小窗的用户看不到退出钮、也找不到拖动带，而无边框窗口没有系统标题栏可退。
- 退小窗**复位**，下次进小窗从「常态清爽」开始，不继承上一次按出来的状态。
- 同时把字幕底部避让里的按钮行一项在 mini 档按 0 算（那一档 `bottomButtonBar` 传空）：
  否则 media_kit 因 hover 翻 `visible`（尽管它在这一档一个像素都画不出来）时，字幕会为
  一条根本不存在的按钮行凭空上移一格。

新动作 `ShortcutAction.videoToggleMiniChrome`，默认 **Shift+M**（裸 M 在 video 组是静音，
而阅读器 / 漫画的「切换界面」正是裸 M，Shift+M 既避冲突又留住肌肉记忆），并进
`kVideoPressEdgeOnlyActions`——翻转型动作按住连发就是一片闪烁的按钮。常规窗口 / 系统
画中画下按它是 no-op（那两处 chrome 分别归 media_kit 与系统），执行体自己早退，不留一个
没人读的标志位。

## 底部细进度条（对上参考图三）

`lib/src/media/video/video_slim_progress_bar.dart`，偏好 `video_slim_progress_bar`，
**默认关**（首版默认开，2026-09-22 改判）——控制条淡出本身就是「把画面让干净」，
再留一条常亮的线等于把这个意图撤回一半；想要的人去设置里开。已手动切过开关的用户
不受影响：`getPref` 只在该 key 从未写过时才返回默认值。

- 颜色走播放器 chrome 的既定口径 `videoChromeAccentColor(cs)`（恒取亮 tone primary），
  **不是**裸 `colorScheme.primary`：浅色 / eink 主题下 primary 是深色，压在 fork 的固定
  深色 scrim 上黑压黑不可读。
- 组件**不接** `VideoPlayerController` 而只收两个取值回调：controller 的
  `notifyListeners` 是按「当前字幕 cue 变化」节流的，拿它驱动会得到一条一句一跳的线；
  反过来让它逐帧通知，整页的监听者都要跟着重建。故自己按 200ms 轮询，且只在比例真的
  变了才 `setState`。回调形态顺带让它可以被纯 widget 测试驱动（无需真 libmpv）。
- 显隐三条规则（优先级从高到低）：系统画中画恒不显（与系统控件重影）→ mini 档恒显
  （那里完整进度条已被收起，细线是唯一进度指示，不受开关管）→ 常规档「开关开 + 控制条
  已淡出」。

### 追加（同日用户反馈）：细线可直接点击 / 横拖跳转

> 「下面那个细进度条也顺手增加可以直接点击跳转控制吧，应该也很难误触。」

小窗里它已经是**唯一**的进度控件（chrome 收起后更是唯一还在的控件），常规档它是控制条
淡出后唯一还在的那条，所以「只能看不能点」是个明显缺口。

- 换算走纯函数 `videoSlimProgressSeekFraction({dx, width})`，与 media_kit fork 那条常规
  进度条同口径（细线没有横向 margin，分母就是自身宽度）；宽度未就绪返回 **null**（不是 0）
  ——返回 0 会把首帧的一次误触变成「跳回片头」。
- 可见线仍是 3 像素，**向上补一段 12 像素的透明命中带**：3 像素鼠标瞄不准、触屏更不可能；
  再高就容易把本该落到画面的单击吃掉。
- 命中带用 `HitTestBehavior.opaque`：media_kit 的「点画面暂停」收不到这次 tap（点线只跳转，
  不顺手翻播放态）；页面最外层那条 translucent `Listener` 仍收到 pointer-up，但它的
  `_isVideoChromePointer` 早把底部整条带判为 chrome，不会触发双击全屏。
- 跳转走 `controller.seekMs`，**不是** media_kit 的 `player.seek`——后者绕过本仓 controller，
  seek 在途保护与字幕权威同步都不跟着走（BUG-796 就是这么来的）。也刻意**不**唤起控制条：
  这条线存在的意义就是「控制条不在时也能操作」。
- 横拖按 100ms 限频（每帧提交会让播放器被 seek 淹没），**松手的终值无条件补发一次**；落点
  乐观立即到位并在 500ms 内不被回读覆盖（否则松手后线会先弹回原处再跳过去，看着像点歪了）。
- 沉浸锁 / 侧面板 / 剧集轨 / 控件编辑态下回调传 **null**（组件退回纯装饰形态）：细线挂在
  media_kit 控制条那层 `IgnorePointer` **之外**，不自己订阅这四个门控，它就是它们唯一漏掉的
  可点区。

## 入口

`ShortcutAction.videoToggleMiniWindow`，默认裸 **W**（video co-active 组内唯一未被占用
的助记字母）。登记进 `kVideoAssignableActions` 后，键盘、手柄、以及画面上的
「快捷键 1~4」可配置按钮三条入口一次拿到，不必再单开一个控制条槽位。

## 测试

| 层 | 文件 |
|---|---|
| 密度判据 + 细进度条显隐（纯函数） | `test/media/video/video_controls_density_test.dart` |
| 细进度条渲染（widget） | `test/media/video/video_slim_progress_bar_test.dart` |
| 页面接线（源码守卫） | `test/pages/video_slim_progress_bar_wiring_guard_test.dart` |
| 小窗接线 + chrome 只认显式唤出（源码守卫） | `test/pages/video_mini_window_wiring_guard_test.dart` |
| 桌面小窗几何 + 几何记忆闸门 | `test/platform/desktop_mini_window_mode_test.dart` |
| PiP 比例钳制 + 通道行为 | `test/platform/android_picture_in_picture_test.dart` |

media_kit 的控制条在 headless 宿主渲染不出来（无 libmpv），所以 theme 侧的取舍只能
静态断——这也是本页其余一整批守卫都是源码级的原因。

## 未验证项（如实记录）

- **桌面小窗的真实窗口行为**（无边框观感、置顶、拖动、退出还原、多显示器摆位）只跑了
  单元测试，**没有在真机 Windows 上目视确认**。
- **Android 系统画中画**：Java 侧 `:app:compileDebugJavaWithJavac` 真编过，Dart 侧通道
  行为有打桩测试，但**没有在模拟器/真机上实际进过一次 PiP**。
- mini 档下的字幕悬停制卡链路是「结构上零改动继续可用」的推断（overlay 与判据都没动），
  未在真机复测。chrome 改成默认收起后这条推断更强了一点（收起态 `FadingChromeGate` 直接
  `IgnorePointer`，画面上再没有别的层抢指针），但仍未真机复测。
- **细线点击跳转**只有 widget 测试（命中带几何、落点换算、限频与终值补发）。真机上「12 像素
  命中带会不会误触」「小窗里拇指/鼠标能不能瞄准」没有验证过，用户接受这个风险（原话
  「应该也很难误触」）。
- **Shift+M 唤出 chrome** 走的是与其它视频快捷键同一条 press-time 通道（有分发测试），但
  没有在真机小窗里按过。
