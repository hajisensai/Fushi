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
    // 进入字级选词光标的**键盘绑定同样永不进本表**（默认 Enter）。本表被装进
    // media_kit 桌面 controls 的 `keyboardShortcuts`，即一个 [CallbackShortcuts]，
    // 而它**包住整个 controls 子树**（顶栏 / 底栏按钮全在里面）、一旦 activator
    // 匹配就无条件返回 handled——回调里再怎么判断也收不回这次消费。Enter 是本 app
    // 的全局焦点确认键（裸空格已被中和成 DoNothingIntent，见 `global_navigation.dart`），
    // 装进这张表等于把控制条上每个按钮的 Enter 确认整片吃掉：Tab / 手柄把焦点落到
    // 播放 / 全屏 / ±10s 上再按 Enter，按钮不会被按下，而是弹出选词光标。
    // 改由页面最外层 Focus.onKeyEvent 按**焦点归属**做 contextual 判定——只有视频
    // 画面持焦才进光标，焦点在 chrome 按钮上时不消费、放行给 ActivateIntent
    // （[decideVideoEnterCaretKey]，阅读器 `_isCaretEntryTrigger` 同款范式）。
    // 顺带（有意）：任何复用本表的调用点（如字幕对轴弹窗）都不会再意外装上 Enter。
    if (action == ShortcutAction.videoEnterCaret) continue;
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
/// 字级选词光标激活期的键盘接管（videoEnterCaret）：把注册表 activator 表里每个
/// 回调包一层守卫——光标激活时，若该 activator 的**无修饰**触发键在光标键表里
/// （方向键=移动、Enter=查词、Esc=退出，`ReaderCaretRouter.decideKeyboard` 同源），
/// 先走光标动作、不跑原动作（裸方向键不再 seek/调音量）；带 Ctrl/Alt/Meta 的组合键
/// （如 Ctrl+←=上一句）与非光标键照常执行。光标未激活时零行为变化。
///
/// 纯函数、无页面依赖（与 [guardVideoShortcutsWithPopupDismiss] 同范式，可单测）。
/// [runCaretKey] 由页面提供：对 (键, shift) 执行光标动作，返回是否已消费。
Map<ShortcutActivator, VoidCallback> guardVideoShortcutsWithSubtitleCaret(
  Map<ShortcutActivator, VoidCallback> base, {
  required bool Function() isCaretActive,
  required bool Function(LogicalKeyboardKey key, {required bool shift})
      runCaretKey,
}) {
  return base.map(
    (ShortcutActivator activator, VoidCallback callback) => MapEntry(
      activator,
      () {
        if (isCaretActive() && activator is SingleActivator) {
          // Ctrl/Alt/Meta 组合键不是光标键（Ctrl+← 上一句等照常放行）；Shift 作为
          // 光标语义的一部分透传（Shift+Tab=后退一字，与阅读器一致）。
          final bool hasHardModifier =
              activator.control || activator.alt || activator.meta;
          if (!hasHardModifier &&
              runCaretKey(activator.trigger, shift: activator.shift)) {
            return;
          }
        }
        callback();
      },
    ),
  );
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

/// [decideVideoEnterCaretKey] 的判决：一次按键对「进入字级选词光标」意味着什么。
///
/// 把判据和执行分开，是因为这条路径的要害恰恰在「**什么时候不该消费**」——它
/// 必须能表达「命中了绑定键但仍然放行」，而回调式的 [CallbackShortcuts] 表达不了
/// （见 [buildVideoPlayerShortcutsFromRegistry] 里 videoEnterCaret 的 skip 注释）。
enum VideoEnterCaretKeyDecision {
  /// 不是「进入选词光标」的绑定键，或光标已激活 / 焦点在文本框：本层不消费，
  /// 事件按原有路径继续（光标激活期由 `_handleCaretUnboundKey` 接管）。
  notTrigger,

  /// 命中绑定键，但**焦点不在视频画面上**（控制条按钮等其它控件持焦）：一样不
  /// 消费——Enter 在本 app 是全局焦点确认键，必须继续上浮到 WidgetsApp 的
  /// Enter→ActivateIntent，让按钮的 onPressed 照常触发。
  passThrough,

  /// 命中绑定键且有可见词典浮层：先关顶层浮层（BUG-924：浮层可见时任一视频键
  /// 都先关浮层，不穿透去控制后面的视频）。
  dismissPopup,

  /// 命中绑定键且视频画面持焦：进入 / 推进字级选词光标。
  enterCaret,
}

/// videoEnterCaret 的键盘触发判据（纯函数，与本文件另两个 guard 同范式，可单测）。
///
/// [enterActivators] = 注册表里 [ShortcutAction.videoEnterCaret] 的实时键盘绑定
/// （默认 Enter，可重映射），由调用方以 `includeRepeats: false` 构造 → 长按不连发。
/// [videoSurfaceHoldsFocus] = 视频画面的 FocusNode 是否**精确持焦**（`hasPrimaryFocus`）：
/// 这就是阅读器 `_isCaretEntryTrigger` 那条 contextual 判据在视频侧的对应物——
/// 「正文持焦才算选词键」在视频侧就是「画面持焦才算选词键」。
VideoEnterCaretKeyDecision decideVideoEnterCaretKey({
  required KeyEvent event,
  required Iterable<ShortcutActivator> enterActivators,
  required HardwareKeyboard keyboardState,
  required bool caretActive,
  required bool hasEditableFocus,
  required bool hasVisiblePopup,
  required bool videoSurfaceHoldsFocus,
}) {
  if (caretActive || hasEditableFocus) {
    return VideoEnterCaretKeyDecision.notTrigger;
  }
  final bool hit = enterActivators.any(
    (ShortcutActivator activator) => activator.accepts(event, keyboardState),
  );
  if (!hit) return VideoEnterCaretKeyDecision.notTrigger;
  if (hasVisiblePopup) return VideoEnterCaretKeyDecision.dismissPopup;
  if (!videoSurfaceHoldsFocus) return VideoEnterCaretKeyDecision.passThrough;
  return VideoEnterCaretKeyDecision.enterCaret;
}

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
