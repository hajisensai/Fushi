# 视频小窗模式 + 控件密度 + 底部细进度条（2026-09-22）

> 需求来自群内讨论：「给视频功能添加个无边框小窗功能吧，看着精致点」→「看 b 站的小窗口，
> 也可以根据窗口大小缩小一些那些进度条」→「手机咋办」→「添加一个开关把进度条缩小到
> 视频最下方用主题色」。参考图三张：B 站网页小窗（视频浮窗 + 分离侧栏）、iOS 画中画
> （无边框圆角 + 大号居中控件 + 底部细进度条）、B 站网页播放器控制条隐藏后底部那条细线。

## 交付物

三件事，共用一套判据：

1. **控件密度**：控制条按**播放区宽度**分三档（full / compact / mini），越窄越紧凑。
2. **小窗模式**：桌面把主窗变成无边框置顶小窗；Android 进系统画中画；iOS 不提供。
3. **底部细进度条**：独立开关，控制条淡出后在视频最下方留一条主题色细线。

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
- 两者都挂在共享的 `FadingChromeGate` 上，与控制条同一个 `_videoControlsVisible`、
  同速淡入淡出。

## 底部细进度条（对上参考图三）

`lib/src/media/video/video_slim_progress_bar.dart`，偏好 `video_slim_progress_bar`，
**默认开**——它只在控制条**已经不在**时出现，不遮挡任何东西。

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
  未在真机复测。
