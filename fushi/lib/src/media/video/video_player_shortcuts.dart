import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        PhysicalKeyboardKey;
import 'package:flutter/widgets.dart';

import 'package:fushi/src/shortcuts/input_binding.dart'
    show GamepadButton, InputBinding, ModifierKey;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// Coalesces a controller button and the synthetic secondary mouse click that
/// some desktop controller mappers emit for the same physical press.
///
/// Steam Input's desktop layout is a common source: Hibiki receives the real
/// controller button through GameInput, while Windows also receives a right
/// click through the pointer channel. Neither Flutter event carries a shared
/// source identifier, so the only reliable app-side boundary is their tightly
/// correlated arrival time. Real mouse right-clicks outside this narrow window
/// remain untouched.
class VideoGamepadSecondaryTapDeduper {
  /// The desktop gamepad poller ticks every 60 ms. Waiting slightly longer lets
  /// a pointer-first synthetic click meet its controller half before a menu is
  /// opened.
  static const Duration settleDelay = Duration(milliseconds: 80);

  /// Covers either delivery order plus normal UI-thread scheduling jitter.
  static const Duration coincidenceWindow = Duration(milliseconds: 120);

  Duration? _lastGamepadPressAt;

  void recordGamepadPress(Duration at) {
    _lastGamepadPressAt = at;
  }

  bool shouldSuppressSecondaryTap(Duration tapAt) {
    final Duration? gamepadAt = _lastGamepadPressAt;
    if (gamepadAt == null) return false;
    final Duration delta = gamepadAt - tapAt;
    return delta.abs() <= coincidenceWindow;
  }
}

class VideoPlayerShortcutActions {
  const VideoPlayerShortcutActions({
    required this.togglePlayPause,
    required this.play,
    required this.pause,
    required this.previousSubtitle,
    required this.nextSubtitle,
    required this.seekBackward,
    required this.seekForward,
    required this.toggleShaderCompare,
    required this.volumeUp,
    required this.volumeDown,
    required this.toggleMute,
    required this.speedUp,
    required this.speedDown,
    required this.resetSpeed,
    required this.toggleHoldSpeed,
    required this.previousFrame,
    required this.nextFrame,
    required this.screenshot,
    required this.toggleFullscreen,
    required this.toggleSubtitleList,
    required this.toggleImmersiveLock,
    required this.toggleSubtitleBlur,
    required this.cycleSubtitleObscure,
    required this.toggleSubtitleHide,
    required this.cycleSecondarySubtitleObscure,
    required this.toggleSecondarySubtitleHide,
    required this.toggleFavoriteSentence,
    required this.replayCurrentSubtitle,
    required this.replayPreviousSubtitle,
    required this.previousChapter,
    required this.nextChapter,
    required this.openSubtitleAlign,
    required this.subtitleDelayIncrease,
    required this.subtitleDelayDecrease,
    required this.alignSubtitleToPrev,
    required this.alignSubtitleToNext,
    required this.enterCaret,
    required this.escape,
  });

  final VoidCallback togglePlayPause;
  final VoidCallback play;
  final VoidCallback pause;
  final VoidCallback previousSubtitle;
  final VoidCallback nextSubtitle;
  final VoidCallback seekBackward;
  final VoidCallback seekForward;
  final VoidCallback toggleShaderCompare;
  final VoidCallback volumeUp;
  final VoidCallback volumeDown;
  final VoidCallback toggleMute;
  final VoidCallback speedUp;
  final VoidCallback speedDown;
  final VoidCallback resetSpeed;

  /// 按住临时倍速（对齐手机长按画面，默认裸 E）。**键盘通道不经本表**：按住语义
  /// 需要 keyup 边沿，SingleActivator 表达不了，键盘按下/松开由视频页最外层
  /// Focus.onKeyEvent 直接判定（见 _handleHoldSpeedKey）。本回调只服务手柄通道
  /// （videoActionCallbacks → resolveGamepad 派发），退化成翻转语义：按一下切到
  /// 长按倍速、再按恢复原速。
  final VoidCallback toggleHoldSpeed;
  final VoidCallback previousFrame;
  final VoidCallback nextFrame;
  final VoidCallback screenshot;
  final VoidCallback toggleFullscreen;

  /// 打开/关闭字幕跳转列表面板（TODO-069，默认裸 L 键；asbplayer 式 transcript 列表）。
  final VoidCallback toggleSubtitleList;

  /// 翻转锁定 / 沉浸模式（TODO-101，默认 Shift+L）。锁定后控制条按钮不再随鼠标/触摸弹出，
  /// 视频纯画面播放，但查词与快捷键仍可用；再按一次（或点常驻解锁按钮）退出。
  final VoidCallback toggleImmersiveLock;

  /// 翻转字幕模糊（默认 B 键，asbplayer 同款）。原本挂在 video 本体内层独立
  /// CallbackShortcuts，TODO-134 起并入可重映射注册表，与其它视频键统一。
  final VoidCallback toggleSubtitleBlur;

  /// 循环字幕遮蔽模式（TODO-840 Part B，默认 Shift+B）：不遮蔽 → 模糊 → 隐藏 → …。
  final VoidCallback cycleSubtitleObscure;

  /// 开/关「隐藏主字幕」（TODO-840 Part B，默认 H）：在隐藏与不遮蔽之间切换。
  final VoidCallback toggleSubtitleHide;

  /// 循环**副字幕**遮蔽模式（TODO-1382，默认 Shift+G）：不遮蔽 → 模糊 → 隐藏 → …。
  final VoidCallback cycleSecondarySubtitleObscure;

  /// 开/关「隐藏副字幕」（TODO-1382，默认 Shift+H）：在隐藏与不遮蔽之间切换。
  final VoidCallback toggleSecondarySubtitleHide;

  final VoidCallback toggleFavoriteSentence;
  final VoidCallback replayCurrentSubtitle;

  /// 重播上一句（TODO-378，BUG-287）：纯句子跳转到上一条 cue 起点并播放，不退化回退。
  final VoidCallback replayPreviousSubtitle;

  /// 内封章节上/下一章（TODO-424）：seek 到相邻章起点，无章节时 no-op。
  final VoidCallback previousChapter;
  final VoidCallback nextChapter;

  /// 打开字幕波形对轴放大视图（用户请求，默认 Shift+A）：复用快速设置面板里的
  /// SubtitleWaveformZoomView，一键从键盘直达埋得很深的「字幕调轴」。无字幕 / 无本地
  /// 视频路径 / 移动端抽不到波形时降级弹提示、不弹窗。
  final VoidCallback openSubtitleAlign;

  /// 字幕延迟 +/-（用户请求，默认 z/x）：像 mpv 一样按固定步进整体平移字幕延迟，
  /// 走现有 _setDelayMs 写穿 delayMs 落盘 + OSD 反馈。
  final VoidCallback subtitleDelayIncrease;
  final VoidCallback subtitleDelayDecrease;

  /// asbplayer 式「字幕偏移对齐」（用户请求，默认 Ctrl+Shift+←/→）：把上一句 / 下一句
  /// 字幕的起点整体平移到当前播放点（按目标 cue 求绝对偏移，一键粗对齐整轨）。决策走
  /// 纯函数 VideoPlayerController.snapSubtitleDelayMs，写穿仍经 _setDelayMs（与 z/x 同源）。
  final VoidCallback alignSubtitleToPrev;
  final VoidCallback alignSubtitleToNext;

  /// 进入字级选词光标（videoEnterCaret，默认 Enter / 手柄 Select）。光标已激活时
  /// 本回调等价于「对光标字符查词」（与阅读器 readerLookupAtCursor 的双语义一致）；
  /// 激活期的方向/确认/退出键不经本表，由页面先于注册表截获。
  final VoidCallback enterCaret;

  final VoidCallback escape;
}

/// Maps each video [ShortcutAction] to the callback that runs it. This is the
/// single fixed wiring between the (remappable) registry actions and the
/// concrete player operations; the keys themselves come from the registry so
/// users can rebind them (TODO-134).
/// 能绑到视频页**屏幕按钮**（自定义「快捷键 1..4」）上的动作全集。
///
/// 真相源是 [videoActionCallbacks]：只有它接过线的动作才真的能在本页执行，把别的动作
/// 放进选择列表 = 用户配得上、按了没反应。这里之所以另写一份常量而不是直接取
/// `videoActionCallbacks(...).keys`，是因为**设置页拿不到 live 的
/// [VideoPlayerShortcutActions]**（那需要一个正在播放的 controller），而选择列表在没
/// 打开视频时也要能展示。
///
/// ⚠️ 两份必须一致：守卫测试 `video_custom_action_bindings_test` 用一个哑实例调
/// [videoActionCallbacks] 并与本表逐个比对，漏加 / 多加即红。顺序 = 选择列表的展示
/// 顺序，按「播放 → 字幕 → 对轴 → 音量 → 画面 → 学习」分簇，与设置页快捷键分组同序。
const List<ShortcutAction> kVideoAssignableActions = <ShortcutAction>[
  // 播放控制
  ShortcutAction.videoTogglePlayPause,
  ShortcutAction.videoPlay,
  ShortcutAction.videoPause,
  ShortcutAction.videoSeekBackward,
  ShortcutAction.videoSeekForward,
  ShortcutAction.videoPreviousFrame,
  ShortcutAction.videoNextFrame,
  // 倍速
  ShortcutAction.videoSpeedUp,
  ShortcutAction.videoSpeedDown,
  ShortcutAction.videoResetSpeed,
  ShortcutAction.videoHoldSpeed,
  // 字幕跳转 / 重播
  ShortcutAction.videoPreviousSubtitle,
  ShortcutAction.videoNextSubtitle,
  ShortcutAction.videoReplayCurrentSubtitle,
  ShortcutAction.videoReplayPreviousSubtitle,
  // 章节
  ShortcutAction.videoPreviousChapter,
  ShortcutAction.videoNextChapter,
  // 字幕显示 / 遮蔽
  ShortcutAction.videoToggleSubtitleList,
  ShortcutAction.videoToggleSubtitleBlur,
  ShortcutAction.videoCycleSubtitleObscure,
  ShortcutAction.videoToggleSubtitleHide,
  ShortcutAction.videoCycleSecondarySubtitleObscure,
  ShortcutAction.videoToggleSecondarySubtitleHide,
  // 字幕对轴
  ShortcutAction.videoOpenSubtitleAlign,
  ShortcutAction.videoSubtitleDelayIncrease,
  ShortcutAction.videoSubtitleDelayDecrease,
  ShortcutAction.videoAlignSubtitleToPrev,
  ShortcutAction.videoAlignSubtitleToNext,
  // 音量
  ShortcutAction.videoVolumeUp,
  ShortcutAction.videoVolumeDown,
  ShortcutAction.videoToggleMute,
  // 画面 / 杂项
  ShortcutAction.videoToggleFullscreen,
  ShortcutAction.videoScreenshot,
  ShortcutAction.videoToggleShaderCompare,
  ShortcutAction.videoToggleImmersiveLock,
  // 学习
  ShortcutAction.videoToggleFavoriteSentence,
  ShortcutAction.videoEnterCaret,
  // 「返回上一级」：视频页把它解释成逐级退出阶梯（关字幕列表 → 退侧栏 → … → 退页）。
  ShortcutAction.globalBack,
];

Map<ShortcutAction, VoidCallback> videoActionCallbacks(
  VideoPlayerShortcutActions actions,
) {
  return <ShortcutAction, VoidCallback>{
    ShortcutAction.videoTogglePlayPause: actions.togglePlayPause,
    ShortcutAction.videoPlay: actions.play,
    ShortcutAction.videoPause: actions.pause,
    ShortcutAction.videoPreviousSubtitle: actions.previousSubtitle,
    ShortcutAction.videoNextSubtitle: actions.nextSubtitle,
    ShortcutAction.videoSeekBackward: actions.seekBackward,
    ShortcutAction.videoSeekForward: actions.seekForward,
    ShortcutAction.videoToggleShaderCompare: actions.toggleShaderCompare,
    ShortcutAction.videoVolumeUp: actions.volumeUp,
    ShortcutAction.videoVolumeDown: actions.volumeDown,
    ShortcutAction.videoToggleMute: actions.toggleMute,
    ShortcutAction.videoSpeedUp: actions.speedUp,
    ShortcutAction.videoSpeedDown: actions.speedDown,
    ShortcutAction.videoResetSpeed: actions.resetSpeed,
    ShortcutAction.videoHoldSpeed: actions.toggleHoldSpeed,
    ShortcutAction.videoPreviousFrame: actions.previousFrame,
    ShortcutAction.videoNextFrame: actions.nextFrame,
    ShortcutAction.videoScreenshot: actions.screenshot,
    ShortcutAction.videoToggleFullscreen: actions.toggleFullscreen,
    ShortcutAction.videoToggleSubtitleList: actions.toggleSubtitleList,
    ShortcutAction.videoToggleImmersiveLock: actions.toggleImmersiveLock,
    ShortcutAction.videoToggleSubtitleBlur: actions.toggleSubtitleBlur,
    ShortcutAction.videoCycleSubtitleObscure: actions.cycleSubtitleObscure,
    ShortcutAction.videoToggleSubtitleHide: actions.toggleSubtitleHide,
    ShortcutAction.videoCycleSecondarySubtitleObscure:
        actions.cycleSecondarySubtitleObscure,
    ShortcutAction.videoToggleSecondarySubtitleHide:
        actions.toggleSecondarySubtitleHide,
    ShortcutAction.videoToggleFavoriteSentence: actions.toggleFavoriteSentence,
    ShortcutAction.videoReplayCurrentSubtitle: actions.replayCurrentSubtitle,
    ShortcutAction.videoReplayPreviousSubtitle: actions.replayPreviousSubtitle,
    ShortcutAction.videoPreviousChapter: actions.previousChapter,
    ShortcutAction.videoNextChapter: actions.nextChapter,
    ShortcutAction.videoOpenSubtitleAlign: actions.openSubtitleAlign,
    ShortcutAction.videoSubtitleDelayIncrease: actions.subtitleDelayIncrease,
    ShortcutAction.videoSubtitleDelayDecrease: actions.subtitleDelayDecrease,
    ShortcutAction.videoAlignSubtitleToPrev: actions.alignSubtitleToPrev,
    ShortcutAction.videoAlignSubtitleToNext: actions.alignSubtitleToNext,
    ShortcutAction.videoEnterCaret: actions.enterCaret,
    // 「返回上一级」（universal scope，默认 Esc / Alt+← / 手柄 B）。它不是 video
    // scope 的动作，但执行体属于本页——视频的逐级退出阶梯（控件编辑 → 字幕列表 →
    // 剧集列表 → 侧栏 → 沉浸锁 → 全屏 → 浮层 → 退页）只有本页知道。
    // [buildVideoPlayerShortcutsFromRegistry] 按 action 读 `bindingsFor`（与 scope
    // 无关），故它照常拿到当前绑定、改键立即生效。
    ShortcutAction.globalBack: actions.escape,
  };
}

/// 长按**不**连发的视频动作（按一下翻一次）。TODO-840 Part B 起是模糊切换 / 遮蔽
/// 循环 / 隐藏切换；进入选词光标与制卡同属此类（长按不该连发查词 / 连发制卡）。
///
/// 两条键盘通道共用这一份真相源：弹窗复用的 activator 表把它翻译成
/// `includeRepeats: false`（[buildVideoPlayerShortcutsFromRegistry]），页级
/// press-time 通道把它翻译成「[KeyRepeatEvent] 不消费」
/// （[resolveVideoKeyboardShortcut]）。
const Set<ShortcutAction> kVideoPressEdgeOnlyActions = <ShortcutAction>{
  ShortcutAction.videoToggleSubtitleBlur,
  ShortcutAction.videoCycleSubtitleObscure,
  ShortcutAction.videoToggleSubtitleHide,
  ShortcutAction.videoEnterCaret,
  ShortcutAction.popupMineEntry,
};

/// 把注册表里的视频键盘绑定冻结成一张 `Map<ShortcutActivator, VoidCallback>`
/// （TODO-134）。
///
/// **这不是视频页的主键盘通道**。主通道是 press-time 解析的
/// [resolveVideoKeyboardShortcut]（挂在视频页最外层 `Focus.onKeyEvent`，与手柄
/// [FushiShortcutRegistry.resolveGamepad] 派发同构）。本函数只服务**推到 Navigator
/// 上的独立弹窗**（字幕波形对轴视图）——那些路由不在视频页 Focus 的祖先链上，收不到
/// 主通道，只能自带一张表。
///
/// build 时冻结意味着表建好之后注册表改键不会自动反映到已挂载的弹窗上，也无法表达
/// 「命中了但这次不消费」（见下面两个 `continue` 的注释）；弹窗是短生命周期、按键面
/// 也窄，这两条限制在那里可以接受，在整页主通道上则不行——那正是主通道改成 press-time
/// 的原因。[exclude] 让调用点摘掉会破坏弹窗自身的动作（Esc / 全屏 / 打开字幕列表…）。
Map<ShortcutActivator, VoidCallback> buildVideoPlayerShortcutsFromRegistry(
  FushiShortcutRegistry registry,
  VideoPlayerShortcutActions actions, {
  Set<ShortcutAction> exclude = const <ShortcutAction>{},
}) {
  final Map<ShortcutAction, VoidCallback> callbacks =
      videoActionCallbacks(actions);
  final Map<ShortcutActivator, VoidCallback> result =
      <ShortcutActivator, VoidCallback>{};
  for (final MapEntry<ShortcutAction, VoidCallback> entry
      in callbacks.entries) {
    final ShortcutAction action = entry.key;
    // 调用点可排除个别动作（如字幕对轴弹窗复用本 map 时排除 Escape / 全屏 / 打开字幕列表 /
    // 沉浸锁，避免它们拦掉弹窗自身的关闭或在弹窗后面改变布局）。
    if (exclude.contains(action)) continue;
    // 这两个动作**永远不进 activator 表**，因为它们要表达的语义 [SingleActivator]
    // 根本表达不了；两者都由主通道 [resolveVideoKeyboardShortcut] 在 press-time 处理。
    //
    // · videoHoldSpeed：按住加速 / 松开恢复需要 keyup 边沿，activator 只有按下沿。
    // · videoEnterCaret（默认 Enter）：需要「命中了绑定键但仍然放行」——Enter 是本
    //   app 唯一的焦点确认键（裸空格已被中和成 DoNothingIntent，见
    //   `global_navigation.dart`），焦点落在弹窗按钮上时必须继续上浮到
    //   Enter→ActivateIntent。[CallbackShortcuts] 一旦匹配就无条件 handled，回调里
    //   再怎么判断也收不回这次消费。
    if (action == ShortcutAction.videoHoldSpeed) continue;
    if (action == ShortcutAction.videoEnterCaret) continue;
    final bool includeRepeats = !kVideoPressEdgeOnlyActions.contains(action);
    for (final binding in registry.bindingsFor(action).keyboardBindings) {
      // Last writer wins if two actions share a key; the settings UI's conflict
      // check prevents users from creating that within the video scope, and the
      // defaults are collision-free.
      result[binding.toActivator(includeRepeats: includeRepeats)] = entry.value;
    }
  }
  return result;
}

/// 字级选词光标会话的「暂停 → 再播放」迁移追踪（videoEnterCaret）。
///
/// 光标必须在暂停下工作（activeCues 随播放每帧重算，不暂停必失锚），所以「外部
/// 恢复播放」（用户按空格 / 触屏点画面 / 自动连播）就是「用户不想选词了」，光标
/// 应当自动退出。判据不能只看 `playing == true`——进光标那一下的 pause 是
/// fire-and-forget，还没落地时也是 playing，会当场自退。
///
/// 因此必须先见过一次暂停、再见到播放才算迁移。要害在**初值**：视频本来就是暂停
/// 态时进光标，不会调 pause、播放态不翻转、播放器也就不再通知，「见过暂停」这个
/// 标记如果初始化成 false 就**永远置不上位**，自动退出在这条路径上永久失效
/// （用户按空格续播后光标还活着、方向键继续被吞）。把初值绑进构造函数，让
/// 「进入时是否已暂停」成为类型契约的一部分，这个特殊情况就不存在了。
class SubtitleCaretPauseTracker {
  SubtitleCaretPauseTracker({required bool playingAtEntry})
      : _sawPaused = !playingAtEntry;

  bool _sawPaused;

  /// 已观测到暂停生效（进入时本就暂停，或进入时的 fire-and-forget pause 已落地）。
  bool get sawPaused => _sawPaused;

  /// 喂一次播放器 tick，返回**是否应自动退出光标**。
  bool onTick({required bool playing}) {
    if (!playing) {
      _sawPaused = true;
      return false;
    }
    return _sawPaused;
  }
}

/// BUG-853 / BUG-936 / TODO-847 对齐（视频版）：Windows 微软 IME 激活时裸 Space 的
/// [logicalKey] 会被引擎改写，视频页两条空格「播放/暂停」路径（media_kit controls 的
/// `keyboardShortcuts` 与页级 `_withPageSpaceOverride`）都用
/// `SingleActivator(LogicalKeyboardKey.space)` 匹配 [logicalKey]，故 IME 下按空格暂停
/// 失效。本谓词在 KeyEvent 层按**物理键**还原 Space 语义，命中后由调用方触发
/// togglePlayPause。
///
/// BUG-936 根因修正：旧实现只认 `logicalKey == process` 这一种 IME 改写值，但 Windows
/// 日文 IME 在不同输入模式 / 引擎下把物理空格改写成的 [logicalKey] **未必是**
/// [LogicalKeyboardKey.process]（可能是别的非 space 逻辑键），故 BUG-853 修复真机仍失效。
/// 唯一稳定信号是**物理键** [PhysicalKeyboardKey.space]（USB HID 扫描码，IME 绝不改写）：
/// 只要「物理键是 Space + 逻辑键**不是**裸 [LogicalKeyboardKey.space]（即被 IME 改写过）
/// + 无修饰键 + 无文本框 composing」即命中，覆盖 `process` 及任意其它 IME 改写值。
///
/// 与 [resolveReaderSpaceOverride] 同范式：纯谓词、无平台/时序副作用，可单测。**不**识别
/// 裸 `space`（`logicalKey == space` → 返回 false）——裸 Space 走既有 media_kit
/// SingleActivator 路径、在冒泡到本回退前就被消费，故本谓词只处理它覆盖不到的 IME 死角，
/// 绝不与裸空格双触发（Never break userspace）。[hasEditableFocus] 为 true（文本框正在
/// composing）时返回 false，避免 IME 变换候选词时按空格误触暂停。Space 物理键在所有常见
/// 键盘布局上物理位一致，回退稳定。
bool isVideoImeSpacePlayPause({
  required LogicalKeyboardKey logicalKey,
  required PhysicalKeyboardKey physicalKey,
  required bool hasModifier,
  required bool hasEditableFocus,
}) {
  if (hasModifier) return false;
  if (hasEditableFocus) return false;
  // 物理空格 + 逻辑键被 IME 改写（非裸 space）= IME 场景的空格。裸空格（logicalKey==space）
  // 走既有 SingleActivator 路径，不进本回退。
  return physicalKey == PhysicalKeyboardKey.space &&
      logicalKey != LogicalKeyboardKey.space;
}

/// 按住临时倍速键盘状态机的单步结论（[resolveHoldSpeedKeyTransition]）。
enum HoldSpeedKeyTransition {
  /// 命中绑定的 keydown：进入临时倍速并记录触发键。
  engage,

  /// 按住期间的重复/重入事件：消费掉、状态不变（阻止 OS key-repeat 冒泡成别的行为）。
  swallow,

  /// 触发键的 keyup：恢复原速并清空触发键。
  release,

  /// 与按住倍速无关：不消费，交回既有解析路径。
  none,
}

/// 按住临时倍速的键盘状态机（纯函数，供视频页最外层 Focus.onKeyEvent 调用与单测）。
///
/// 语义与手机长按画面一致：按下进入临时倍速、松开恢复。SingleActivator 只有按下
/// 边沿，表达不了「松开」，故本动作不进 CallbackShortcuts activator 表（见
/// [buildVideoPlayerShortcutsFromRegistry] 的跳过分支），按下/松开都在这里判定。
///
/// [activeTriggerKey] 非空 = 正在按住中。keyup/repeat 只按**触发键本身**识别、
/// 不看修饰键——用户按住期间松开修饰键时 keyup 仍能命中，绝不把倍速卡在加速态。
/// [matchesHoldSpeedBinding] 是 keydown 是否命中注册表绑定（[keyDownMatchesHoldSpeed]），
/// 非 keydown 事件传什么都不影响结论。
HoldSpeedKeyTransition resolveHoldSpeedKeyTransition({
  required KeyEvent event,
  required LogicalKeyboardKey? activeTriggerKey,
  required bool matchesHoldSpeedBinding,
}) {
  if (event is KeyUpEvent) {
    return activeTriggerKey == event.logicalKey
        ? HoldSpeedKeyTransition.release
        : HoldSpeedKeyTransition.none;
  }
  if (event is KeyRepeatEvent) {
    return activeTriggerKey == event.logicalKey
        ? HoldSpeedKeyTransition.swallow
        : HoldSpeedKeyTransition.none;
  }
  if (event is! KeyDownEvent) return HoldSpeedKeyTransition.none;
  if (activeTriggerKey != null) {
    // 已在按住态：同键的再次 down（个别平台把 repeat 报成 down）照旧消费，
    // 其它键不接管。
    return activeTriggerKey == event.logicalKey
        ? HoldSpeedKeyTransition.swallow
        : HoldSpeedKeyTransition.none;
  }
  return matchesHoldSpeedBinding
      ? HoldSpeedKeyTransition.engage
      : HoldSpeedKeyTransition.none;
}

/// keydown 是否命中注册表里 [ShortcutAction.videoHoldSpeed] 的键盘绑定。
///
/// 修饰键取 [HardwareKeyboard] 实时状态（与 SingleActivator 同口径）；physicalKey
/// 透传给 [FushiShortcutRegistry.resolveKeyboard] 供 IME 改写回退（TODO-847）。
/// [hasEditableFocus] 为 true（文本框持焦）时恒不命中，避免输入时误触加速。
bool keyDownMatchesHoldSpeed(
  FushiShortcutRegistry registry,
  KeyDownEvent event, {
  required bool hasEditableFocus,
}) {
  if (hasEditableFocus) return false;
  final Set<ModifierKey> modifiers = <ModifierKey>{
    if (HardwareKeyboard.instance.isControlPressed) ModifierKey.ctrl,
    if (HardwareKeyboard.instance.isShiftPressed) ModifierKey.shift,
    if (HardwareKeyboard.instance.isAltPressed) ModifierKey.alt,
    if (HardwareKeyboard.instance.isMetaPressed) ModifierKey.meta,
  };
  return registry.resolveKeyboard(
        event.logicalKey,
        modifiers: modifiers,
        scope: ShortcutScope.video,
        physicalKey: event.physicalKey,
      ) ==
      ShortcutAction.videoHoldSpeed;
}

/// 手柄重设计 P3：浮层面板（字幕列表 / 剧集轨 / 侧栏）打开时**让位给通用焦点导航**
/// 的按钮集合——D-pad 移焦、A 激活聚焦行（视频页把这些按钮直接交回 GamepadService
/// 兜底，而不是解析成音量 / seek / 播放暂停）。其余按钮照常解析 video scope
/// （LB/RB seek、Y 下一句等在面板开着时仍可用），B 经 universal globalBack 走既有
/// 逐级退出阶梯关面板。
bool isVideoPanelFocusNavButton(GamepadButton button) {
  switch (button) {
    case GamepadButton.dpadUp:
    case GamepadButton.dpadDown:
    case GamepadButton.dpadLeft:
    case GamepadButton.dpadRight:
    case GamepadButton.a:
      return true;
    default:
      return false;
  }
}

/// [isVideoPanelFocusNavButton] 的**键盘对应物**：浮层面板（字幕列表 / 剧集轨 /
/// 侧栏）持焦时让位给 Flutter 通用焦点遍历的按键。
///
/// D-pad 四向 ↔ 裸方向键，一一对应。手柄那侧的 A（激活聚焦行）在键盘侧是 Enter，
/// 它绑着 [ShortcutAction.videoEnterCaret]，由「视频画面**精确**持焦才算选词键」
/// 那条 contextual 判据天然让位（面板持焦时画面必不持焦），不必在这里重复列一遍。
///
/// 只对**无修饰**方向键成立：Ctrl+←/→（上/下一句字幕）、Ctrl+Shift+←/→（字幕偏移
/// 对齐）是明确的视频动作，面板开着时照常执行——这条判据由调用方
/// [resolveVideoKeyboardShortcut] 施加。
bool isVideoPanelFocusNavKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;
}

/// 一次按键在视频页键盘通道里的去向（[resolveVideoKeyboardShortcut] 的判决）。
enum VideoKeyboardDispatch {
  /// 本层**不消费**，事件继续冒泡。涵盖：未绑定、文本框持焦、面板持焦时的裸方向键、
  /// press-edge-only 动作的重复事件、以及「命中了绑定键但按 contextual 判据应放行」
  /// （videoEnterCaret 在画面不持焦时）。
  ignore,

  /// 执行 [VideoKeyboardResolution.action] 并消费。
  run,

  /// 命中了某个视频动作，但有可见词典浮层：先关顶层浮层并消费（BUG-924）。
  dismissPopup,
}

/// [resolveVideoKeyboardShortcut] 的判决 + 命中的动作。
@immutable
class VideoKeyboardResolution {
  const VideoKeyboardResolution(this.dispatch, [this.action]);

  final VideoKeyboardDispatch dispatch;

  /// 仅 [VideoKeyboardDispatch.run] 时非空。
  final ShortcutAction? action;

  static const VideoKeyboardResolution ignored =
      VideoKeyboardResolution(VideoKeyboardDispatch.ignore);
  static const VideoKeyboardResolution dismissPopup =
      VideoKeyboardResolution(VideoKeyboardDispatch.dismissPopup);

  @override
  bool operator ==(Object other) =>
      other is VideoKeyboardResolution &&
      other.dispatch == dispatch &&
      other.action == action;

  @override
  int get hashCode => Object.hash(dispatch, action);

  @override
  String toString() => 'VideoKeyboardResolution($dispatch, $action)';
}

/// 当前物理修饰键状态（与 [SingleActivator] 同口径），供 press-time 解析取值。
Set<ModifierKey> currentKeyboardModifiers(HardwareKeyboard keyboard) {
  return <ModifierKey>{
    if (keyboard.isControlPressed) ModifierKey.ctrl,
    if (keyboard.isShiftPressed) ModifierKey.shift,
    if (keyboard.isAltPressed) ModifierKey.alt,
    if (keyboard.isMetaPressed) ModifierKey.meta,
  };
}

/// 字级选词光标激活期，一次键盘事件是否**先于注册表解析**交给光标路由
/// （`ReaderCaretRouter.decideKeyboard`）。
///
/// 选词是模态操作：激活期的裸方向键是移动光标，不是 seek / 调音量。但**带硬修饰
/// （Ctrl/Alt/Meta）的组合键不是光标键**——Ctrl+←/→ 是上/下一句字幕、Ctrl+Shift+←/→
/// 是字幕偏移对齐，光标激活时照常执行（跳句后页面会自动重锚）。Shift 不算硬修饰：
/// 它是光标语义的一部分（Shift+Tab = 后退一字，与阅读器一致），透传给光标路由。
///
/// 方案 D 之前这条豁免写在套在 media_kit 表外面的 caret 守卫里，键盘通道合并为一条
/// 之后搬到这里。少了它，光标一开 Ctrl+← 就变成「光标左移一字」。
bool videoCaretKeyboardTakesPrecedence({
  required KeyEvent event,
  required Set<ModifierKey> modifiers,
  required bool caretActive,
  required bool hasEditableFocus,
}) {
  if (!caretActive) return false;
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
  if (hasEditableFocus) return false;
  return !modifiers.contains(ModifierKey.ctrl) &&
      !modifiers.contains(ModifierKey.alt) &&
      !modifiers.contains(ModifierKey.meta);
}

/// 视频页键盘通道的 **press-time 解析**：每次按键当场问注册表要动作，与手柄通道
/// （[FushiShortcutRegistry.resolveGamepad] → [videoActionCallbacks] 派发）同构。
///
/// 为什么不是一张 activator 表：[CallbackShortcuts] 一旦 activator 匹配就**无条件**
/// 返回 handled，表达不了「命中了但这次不该消费」。视频页恰恰有三处必须这么表达——
/// 按住倍速要 keyup 边沿、Enter 在 chrome 持焦时要放行给焦点确认、面板持焦时裸方向键
/// 要让位给焦点遍历——旧实现只能靠「把这些动作从表里剔除 + 在别处另写一条路径」绕开，
/// 每绕一次就多一个特例分支和一处真相源。press-time 解析让「不消费」成为一等结论，
/// 三个特例收敛回同一个判决函数。build 时冻结的另一个毛病也一并消失：全屏路由的
/// `pageBuilder` 只跑一次，冻结的表在那条路径上会陈旧，press-time 永远读当前注册表。
///
/// 纯函数（[modifiers] 由调用方用 [currentKeyboardModifiers] 取），无页面依赖，可单测。
/// 判据顺序即优先级，逐条都对应一条既有语义，改动顺序会改行为。
VideoKeyboardResolution resolveVideoKeyboardShortcut(
  FushiShortcutRegistry registry,
  KeyEvent event, {
  required Set<ModifierKey> modifiers,
  required bool hasEditableFocus,
  required bool hasVisiblePopup,
  required bool videoSurfaceHoldsFocus,
  required bool panelHoldsFocusNavigation,
}) {
  // 只解析按下 / 重复沿。keyup 属于按住倍速状态机（页面在本函数之前一层处理）。
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return VideoKeyboardResolution.ignored;
  }
  // 文本框持焦（含 IME composing）：整条键盘通道让位给输入，一个视频动作都不解析。
  if (hasEditableFocus) return VideoKeyboardResolution.ignored;

  // 手柄重设计 P3 的键盘对应物：面板持焦时裸方向键让位给通用焦点遍历（见
  // [isVideoPanelFocusNavKey]）。必须在解析之前——方向键在注册表里绑着 seek / 音量，
  // 解析之后再让位就等于「先执行再后悔」。
  if (panelHoldsFocusNavigation &&
      modifiers.isEmpty &&
      isVideoPanelFocusNavKey(event.logicalKey)) {
    return VideoKeyboardResolution.ignored;
  }

  final ShortcutAction? action = _resolveVideoKeyboardAction(
    registry,
    event,
    modifiers,
  );
  if (action == null) return VideoKeyboardResolution.ignored;

  // 长按不连发的动作：重复沿不消费（等价旧表的 includeRepeats:false）。
  if (event is KeyRepeatEvent && kVideoPressEdgeOnlyActions.contains(action)) {
    return VideoKeyboardResolution.ignored;
  }

  // 按住临时倍速：keyup 边沿语义，由页面的状态机独占（本函数之前一层已消费按下沿）。
  if (action == ShortcutAction.videoHoldSpeed) {
    return VideoKeyboardResolution.ignored;
  }

  // 制卡（popupMineEntry）必须绕开下面那条「浮层可见 → 先关浮层」：它恰恰只在浮层
  // 可见时才有意义，被守卫吃掉就永远制不了卡（旧实现靠「合并在守卫之后」达到同样
  // 效果）。浮层不可见时照旧消费成 no-op（执行体自带 idx<0 早返回）。
  if (action == ShortcutAction.popupMineEntry) {
    return const VideoKeyboardResolution(
      VideoKeyboardDispatch.run,
      ShortcutAction.popupMineEntry,
    );
  }

  // 进入字级选词光标：命中绑定键（默认 Enter）但**画面不精确持焦**时必须放行，让
  // Enter 继续上浮到 WidgetsApp 的 Enter→ActivateIntent，否则控制条 / 面板上每个
  // 按钮的焦点确认被整片吃掉。浮层可见优先于焦点判据（与旧 decideVideoEnterCaretKey
  // 的分支顺序一致）。
  if (action == ShortcutAction.videoEnterCaret) {
    if (hasVisiblePopup) return VideoKeyboardResolution.dismissPopup;
    if (!videoSurfaceHoldsFocus) return VideoKeyboardResolution.ignored;
  }

  // BUG-924：浮层可见时任一已绑视频键先关顶层浮层，不穿透去控制后面的视频。
  if (hasVisiblePopup) return VideoKeyboardResolution.dismissPopup;
  return VideoKeyboardResolution(VideoKeyboardDispatch.run, action);
}

/// 按键 → 动作的查表部分（[resolveVideoKeyboardShortcut] 内部）。
///
/// 解析顺序 = 旧 activator 表的写入优先级：制卡键最后写入、覆盖同键的视频动作，故这里
/// 最先查；video scope 未命中才落到 universal（globalBack 的逐级退出），与手柄
/// [FushiShortcutRegistry.resolveGamepad] 的两段式兜底逐字对应。
ShortcutAction? _resolveVideoKeyboardAction(
  FushiShortcutRegistry registry,
  KeyEvent event,
  Set<ModifierKey> modifiers,
) {
  final InputBinding target = InputBinding(
    key: event.logicalKey,
    modifiers: modifiers,
  );
  for (final InputBinding binding
      in registry.bindingsFor(ShortcutAction.popupMineEntry).keyboardBindings) {
    if (binding == target) return ShortcutAction.popupMineEntry;
  }
  return registry.resolveKeyboard(
        event.logicalKey,
        modifiers: modifiers,
        scope: ShortcutScope.video,
        physicalKey: event.physicalKey,
      ) ??
      registry.resolveKeyboard(
        event.logicalKey,
        modifiers: modifiers,
        scope: ShortcutScope.universal,
        physicalKey: event.physicalKey,
      );
}
