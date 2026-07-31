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

import 'package:hibiki/src/shortcuts/input_binding.dart' show ModifierKey;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

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

  final VoidCallback escape;
}

/// Maps each video [ShortcutAction] to the callback that runs it. This is the
/// single fixed wiring between the (remappable) registry actions and the
/// concrete player operations; the keys themselves come from the registry so
/// users can rebind them (TODO-134).
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
    ShortcutAction.videoEscape: actions.escape,
  };
}

/// Builds the `Map<ShortcutActivator, VoidCallback>` for the video player from
/// the live registry's video-scope bindings (TODO-134). Every keyboard binding
/// the user has mapped to a video action becomes a [SingleActivator] pointing
/// at that action's callback, so rebinding in the shortcut settings page takes
/// effect immediately. The subtitle-blur toggle stays press-edge-only
/// (includeRepeats:false) to preserve its previous non-repeating behaviour.
Map<ShortcutActivator, VoidCallback> buildVideoPlayerShortcutsFromRegistry(
  HibikiShortcutRegistry registry,
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
    // 按住临时倍速的**键盘绑定永不进本表**：按住语义需要 keyup 边沿，装成
    // SingleActivator 会在 keydown 就把事件消费掉，页面级 Focus.onKeyEvent 的
    // 按下/松开判定（_handleHoldSpeedKey）就永远收不到。手柄通道不受影响——
    // resolveGamepad 派发仍走 videoActionCallbacks 里的 toggleHoldSpeed。
    if (action == ShortcutAction.videoHoldSpeed) continue;
    // 模糊切换 / 遮蔽循环 / 隐藏切换都是 press-edge-only（按一下翻一次，长按不连发，
    // 与历史 videoToggleSubtitleBlur 同语义）。TODO-840 Part B。
    const Set<ShortcutAction> pressEdgeOnly = <ShortcutAction>{
      ShortcutAction.videoToggleSubtitleBlur,
      ShortcutAction.videoCycleSubtitleObscure,
      ShortcutAction.videoToggleSubtitleHide,
    };
    final bool includeRepeats = !pressEdgeOnly.contains(action);
    for (final binding in registry.bindingsFor(action).keyboardBindings) {
      // Last writer wins if two actions share a key; the settings UI's conflict
      // check prevents users from creating that within the video scope, and the
      // defaults are collision-free.
      result[binding.toActivator(includeRepeats: includeRepeats)] = entry.value;
    }
  }
  return result;
}

/// BUG-924：词典浮层开着时，让**任一**已映射的视频快捷键先关掉顶层浮层并消费掉这一次
/// 按键，而不是穿透去控制后面的视频（对齐阅读器：浮层可见时导航/退出类键先关浮层，见
/// `reader_hibiki/caret.part.dart` 的 `readerDismissDict` 及各键 `isDictionaryShown` 分支）。
///
/// 纯函数、无页面依赖，方便单测：把 [base] 里每个回调包一层守卫——[isPopupVisible] 为真时
/// 调 [dismissPopup] 关一层浮层后 return（不跑原动作）；为假时原样执行 [base] 的回调。视频
/// scope 没有任何「作用于浮层本身」的快捷键（制卡走浮层内按钮，非视频快捷键），故整表统一
/// 守卫等价于阅读器的逐键 `isDictionaryShown` 判定，不误吞需要作用于浮层的键。
Map<ShortcutActivator, VoidCallback> guardVideoShortcutsWithPopupDismiss(
  Map<ShortcutActivator, VoidCallback> base, {
  required bool Function() isPopupVisible,
  required VoidCallback dismissPopup,
}) {
  return base.map(
    (ShortcutActivator activator, VoidCallback callback) => MapEntry(
      activator,
      () {
        if (isPopupVisible()) {
          dismissPopup();
          return;
        }
        callback();
      },
    ),
  );
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
/// 透传给 [HibikiShortcutRegistry.resolveKeyboard] 供 IME 改写回退（TODO-847）。
/// [hasEditableFocus] 为 true（文本框持焦）时恒不命中，避免输入时误触加速。
bool keyDownMatchesHoldSpeed(
  HibikiShortcutRegistry registry,
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
