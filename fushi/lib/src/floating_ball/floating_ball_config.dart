/// 悬浮球的场景、按钮目录与持久化编解码（设计见
/// `docs/specs/2026-09-28-floating-ball.md`）。
///
/// 设置 → 悬浮球 是唯一的配置入口：两个独立开关（应用内 / 应用外）+ 每个场景一组
/// 按钮勾选。页面只登记「本页能提供哪些按钮」（[FloatingBallScene]），显示哪些、
/// 按什么顺序由这里的目录与用户勾选决定。
library;

import 'dart:io' show Platform;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi/src/reader/reader_control_layout.dart';

/// 测试缝，与 `GlobalLookupController.platformOverride` 同形：「这台机器有没有
/// 桌面应用外球」与起停 / 按钮过滤 / 动作分发这些 Dart 逻辑正交。不覆盖的话，
/// 覆盖桌面分支的宿主测试只能在 Windows / macOS 上跑，Linux CI 恒跳过。
@visibleForTesting
bool? debugDesktopSystemBallPlatformOverride;

/// Windows / macOS：应用外悬浮球是 runner 自绘的置顶窗口（与应用内球同时在）。
bool get isDesktopSystemBallPlatform =>
    debugDesktopSystemBallPlatformOverride ??
    (Platform.isWindows || Platform.isMacOS);

/// 应用外（系统级）悬浮球此刻是否该给应用内球让位（隐藏）。两颗球同时出现在
/// Fushi 里是重复入口（群反馈：歌词页右侧并排两颗球），所以：
///
///  - 只在「应用内悬浮球」开关开着、且当前场景还勾着按钮时让位（[inAppBallEnabled]，
///    宿主把两者合在一起传）——用户关了应用内球、或把这一场景的按钮全取消了（应用
///    内球因此不画，BUG-3687），前台也保留应用外球，否则 Fushi 里一颗球都没有。页面临时不画球（场景
///    要求隐藏、本页点了关闭、截屏中）不算关掉，照样让位：那是页面 / 用户此刻
///    不要球，不是要另一颗球顶上。
///  - 「在前台」按平台分：
///    - 桌面（[desktop]）只认 [AppLifecycleState.resumed]：主窗失焦只到
///      inactive，那时用户在用别的程序，正是应用外球该露面的时候。
///    - Android 认 [mobileForeground]（宿主按 resumed → true、paused / hidden →
///      false、inactive / detached 维持原判算出的「在前台」）：下拉通知栏、系统
///      对话框只到 inactive，不该让球闪一下。分屏多窗口时 Fushi 那一格是
///      resumed，仍算前台、球照样让位（应用内球就在那一格里）。
///    - Android 画中画（[inPictureInPicture]）一律不让位：Fushi 只剩一个小窗，
///      用户在用别的应用。
///
/// 只决定显隐，不碰开关与位置：两颗球的「显示」开关与停靠位置各存各的，前后台
/// 切换不会把用户关掉的应用外球打开（关着时原生球根本没起）。
bool floatingBallSystemBallYieldsToInApp({
  required bool inAppBallEnabled,
  required AppLifecycleState lifecycle,
  required bool mobileForeground,
  required bool desktop,
  required bool inPictureInPicture,
}) {
  if (!inAppBallEnabled) return false;
  if (desktop) return lifecycle == AppLifecycleState.resumed;
  if (inPictureInPicture) return false;
  return mobileForeground;
}

/// 悬浮球所处的场景：应用内按当前页面的语料分，应用外是 Android 系统球。
enum FloatingBallScope {
  /// 小说 / 有声书阅读器。
  reader('reader'),

  /// 漫画阅读器。
  manga('manga'),

  /// 视频播放页。
  video('video'),

  /// 其它没有登记场景的应用内页面（书架、首页、设置……）。
  general('general'),

  /// 应用外：原生系统球——Android 悬浮窗服务，Windows / macOS 置顶窗口。
  system('system');

  const FloatingBallScope(this.storageValue);

  final String storageValue;

  /// 本平台有没有应用外悬浮球：Android（悬浮窗服务）与 Windows / macOS（原生
  /// 置顶窗口）有；iOS 不允许应用外悬浮，Linux 没有实现。
  static bool systemBallSupported({
    required bool isAndroid,
    bool isDesktop = false,
  }) => isAndroid || isDesktop;

  /// 本平台能配置的场景（应用外那组见 [systemBallSupported]）。
  static List<FloatingBallScope> availableOn({
    required bool isAndroid,
    bool isDesktop = false,
  }) => systemBallSupported(isAndroid: isAndroid, isDesktop: isDesktop)
      ? values
      : <FloatingBallScope>[
          for (final FloatingBallScope scope in values)
            if (scope != system) scope,
        ];

  /// 本场景的专属按钮 id（页面登记时用同一个 id），按目录顺序。
  List<String> get sceneButtonIds => switch (this) {
    reader => <String>[
      for (final ReaderControlItem item in ReaderControlItem.values)
        if (item != ReaderControlItem.title) item.storageValue,
    ],
    manga => kMangaFloatingBallButtons,
    video => kVideoFloatingBallButtons,
    general || system => const <String>[],
  };

  /// 本场景可勾选的全部按钮：专属按钮在前，全局按钮在后（平台可用性由调用方
  /// 用 [FloatingBallGlobalAction.availableOn] 再筛）。
  List<String> get catalog => <String>[
    ...sceneButtonIds,
    for (final FloatingBallGlobalAction action
        in FloatingBallGlobalAction.values)
      action.storageValue,
  ];

  /// 出厂按钮：阅读器是阅读计时开关 + 有声书的上一句 / 播放暂停 / 下一句（后三颗
  /// 沿用旧阅读器内置球的出厂槽位），漫画 / 视频是全部专属按钮；再加本场景出厂
  /// 勾上的全局按钮（[FloatingBallGlobalAction.onByDefaultIn]）。
  List<String> get defaultButtons => <String>[
    ...switch (this) {
      reader => <String>[
        ReaderControlItem.studyTimer.storageValue,
        ReaderControlItem.audiobookPrev.storageValue,
        ReaderControlItem.audiobookPlayPause.storageValue,
        ReaderControlItem.audiobookNext.storageValue,
      ],
      _ => sceneButtonIds,
    },
    for (final FloatingBallGlobalAction action
        in FloatingBallGlobalAction.values)
      if (action.onByDefaultIn(this)) action.storageValue,
  ];

  /// 阅读器 / 漫画 / 视频：球上已经有一整排本页专属按钮。
  bool get isMediaScene => this == reader || this == manga || this == video;

  /// 逗号分隔的持久化值 → 按钮 id（保持目录顺序、去掉未知值与重复）。
  /// 空串 = 从没设过 → [defaultButtons]；用户全部关掉存的是 `-`。
  List<String> decodeButtons(String raw) {
    if (raw.isEmpty) return defaultButtons;
    final Set<String> ids = raw.split(',').map((String s) => s.trim()).toSet();
    return <String>[
      for (final String id in catalog)
        if (ids.contains(id)) id,
    ];
  }

  String encodeButtons(Iterable<String> ids) {
    final Set<String> set = ids.toSet();
    final List<String> ordered = <String>[
      for (final String id in catalog)
        if (set.contains(id)) id,
    ];
    return ordered.isEmpty ? '-' : ordered.join(',');
  }
}

/// 视频页专属按钮 id。
const List<String> kVideoFloatingBallButtons = <String>[
  'play_pause',
  'prev_cue',
  'next_cue',
  'favorite',
  'screenshot',
];

/// 漫画页专属按钮 id。整卷 OCR / 重跑 / 章节目录只在满足条件时由页面提供。
const List<String> kMangaFloatingBallButtons = <String>[
  'previous',
  'next',
  'ocr_boxes',
  'ocr_volume',
  'ocr_rerun',
  'chapters',
];

/// 不随场景变化、任何场景都能放的按钮。
enum FloatingBallGlobalAction {
  /// 在主窗里查词：应用内是输入框 → 应用内查词弹窗；应用外球把 Fushi 唤到前台并
  /// 打开查词页（与桌面「唤起主窗并打开查词页」同一语义）。
  lookup('lookup'),

  /// 应用外查词：不进主窗，弹出与系统「处理文本」/ 截屏识字同一个独立查词窗
  /// （Android `PopupDictFlutterActivity`，盖在当前画面上，只有搜索栏）。
  popupLookup('popup_lookup'),

  /// 读剪贴板查词。
  clipboard('clipboard'),

  /// 截屏 → 系统 OCR → 点字查词。
  screenOcr('screen_ocr'),

  /// 相机拍照（纸质书、招牌、别的设备的屏幕）→ 系统 OCR → 点字查词。应用外球
  /// 把 Fushi 唤到前台再开相机（拍照与识别都在主窗里做）。
  cameraOcr('camera_ocr'),

  /// 立即同步：与设置页「立即同步」、媒体页下拉刷新同一个入口
  /// （`runManualSyncWithFeedback`）。应用外球把 Fushi 唤到前台再同步——结果、
  /// 冲突裁决与重新登录提示都在主窗里给。
  sync('sync'),

  /// 切换配置（Profile）：弹出配置列表，点一项即切过去——与查词弹窗顶栏「制卡
  /// 目标」菜单、设置页配置选择器同一条 `ProfileViewModel.switchProfile`。应用外球
  /// 把 Fushi 唤到前台再弹（配置在主窗的数据库里）。
  switchProfile('switch_profile'),

  /// 反馈：截下当前画面后打开反馈中心（与首页顶栏的反馈按钮同一个入口
  /// `openFeedbackCenter`）。只在应用内球上：截图截的是 Fushi 自己的页面，应用外
  /// 球浮在别的程序上，截不到也没有页面可附。
  feedback('feedback'),

  /// AI 助手（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.4）：
  /// 应用内球在当前页上方弹 AI 浮层（手机半屏面板 / 桌面靠边侧栏），按场景带上
  /// 当前书 / 视频 / 页面作上下文；应用外球把 Fushi 唤到前台再开浮层。AI 模块关着
  /// 时宿主不出这颗按钮；没指派提供商时照常出，点了引导去设置、不发请求。
  ai('ai');

  const FloatingBallGlobalAction(this.storageValue);

  final String storageValue;

  /// 在 [scope] 的球上出厂勾不勾上（都能在 设置 → 悬浮球 里自己勾 / 取消）：
  ///
  /// - 同步各场景都不勾：多数人没配同步后端，出厂就塞一颗点了只会说「同步不可用」
  ///   的按钮是噪音。切换配置同理：多数人只有一份配置。
  /// - 应用外球：其余全勾——它本来就是给别的程序用的这些入口。
  /// - 阅读器 / 漫画 / 视频只勾「查词」与「反馈」：球上已有一整排本页专属按钮，
  ///   再叠上应用外查词 / 剪贴板 / 截屏识字 / 拍照这些与当前媒体无关的入口，漫画页
  ///   出厂就是十一颗按钮的长列（用户 2026-10-14 截图反馈；反馈保留）。
  /// - 其它应用内页面：除「应用外查词」外都勾——在 Fushi 里面它只是另开一个独立
  ///   查词窗，与「查词」重复。
  bool onByDefaultIn(FloatingBallScope scope) {
    if (this == sync || this == switchProfile) return false;
    // AI：四个应用内场景默认放进按钮组，应用外球默认不勾（spec §6.4）。
    if (this == ai) return scope != FloatingBallScope.system;
    if (scope == FloatingBallScope.system) return true;
    if (scope.isMediaScene) return this == lookup || this == feedback;
    return this != popupLookup;
  }

  static FloatingBallGlobalAction? fromStorage(String raw) {
    for (final FloatingBallGlobalAction action in values) {
      if (action.storageValue == raw) return action;
    }
    return null;
  }

  /// 本平台有没有这个能力：截屏 OCR 只有 Android（MediaProjection）与 iOS
  /// （截自己的窗口）接了；拍照查词要系统相机（image_picker 只在移动端有相机）；
  /// 独立查词窗只有 Android 有（`:popup` 进程的透明 Activity），iOS / 桌面没有
  /// 对应组件。
  bool availableOn({required bool isAndroid, required bool isIOS}) =>
      switch (this) {
        FloatingBallGlobalAction.screenOcr ||
        FloatingBallGlobalAction.cameraOcr => isAndroid || isIOS,
        FloatingBallGlobalAction.popupLookup => isAndroid,
        _ => true,
      };

  /// 在某个场景的球上有没有这颗按钮。只有桌面的应用外球与众不同：它浮在别的程序
  /// 上面，「应用外查词」在那里就是查前台程序当前选中的文字（与全局查词热键同一条
  /// 路径），截屏识字是截球所在的显示器、在冻结画面上点字（结果用同一张全局查词
  /// 卡），拍照查词桌面不提供；其余场景同 [availableOn]。
  ///
  /// [lookupModuleEnabled]：「查词」模块开着没有。桌面应用外球的「查词」（打开
  /// 查词页）、「应用外查词」与「截屏识字」（都用全局查词覆盖窗）都挂在这个模块
  /// 上——模块关着时查词页没有入口、全局查词也不启动，按钮点了没反应，所以干脆
  /// 不出现。剪贴板查词在覆盖窗不可用时退回主窗查词弹窗，不受影响。
  bool availableIn(
    FloatingBallScope scope, {
    required bool isAndroid,
    required bool isIOS,
    required bool isDesktop,
    required bool lookupModuleEnabled,
  }) {
    if (scope == FloatingBallScope.system &&
        this == FloatingBallGlobalAction.feedback) {
      return false;
    }
    if (scope == FloatingBallScope.system && isDesktop) {
      return switch (this) {
        FloatingBallGlobalAction.lookup ||
        FloatingBallGlobalAction.popupLookup ||
        FloatingBallGlobalAction.screenOcr => lookupModuleEnabled,
        FloatingBallGlobalAction.clipboard => true,
        FloatingBallGlobalAction.cameraOcr => false,
        FloatingBallGlobalAction.sync => true,
        FloatingBallGlobalAction.switchProfile => true,
        FloatingBallGlobalAction.feedback => false,
        FloatingBallGlobalAction.ai => true,
      };
    }
    return availableOn(isAndroid: isAndroid, isIOS: isIOS);
  }
}

/// Android 应用外悬浮球收起态「点一下」做什么。除 [expand] 外都是一步直达的单个
/// 功能，此时长按才展开按钮（只用某一个功能的人不必点两下，反馈 9bdhVTgq3A）。
/// 线协议值即动作 id（原生 `FloatingBallService.TAP_ACTIONS`），[expand] 发空串。
enum FloatingBallTapAction {
  /// 出厂：点球展开按钮。
  expand(''),

  /// 直接查剪贴板（旧版「点球查剪贴板」开关）。
  clipboard('clipboard'),

  /// 直接截屏识字。
  screenOcr('screen_ocr'),

  /// 直接打开 AI 助手（spec §6.4）：Fushi 被拉到前台并打开 AI 浮层。
  ai('ai');

  const FloatingBallTapAction(this.storageValue);

  final String storageValue;

  static const FloatingBallTapAction fallback = expand;

  /// 持久化值 → 档位。[legacyTapClipboard] 是旧版 bool 偏好
  /// `floating_ball.tap_clipboard`：新键从没写过（null）时沿用它。
  static FloatingBallTapAction fromStorage(
    Object? raw, {
    bool legacyTapClipboard = false,
  }) {
    if (raw is! String) return legacyTapClipboard ? clipboard : fallback;
    for (final FloatingBallTapAction value in values) {
      if (value.storageValue == raw) return value;
    }
    return fallback;
  }
}

/// 用户点了「关闭悬浮球」之后，哪些球在回到 Fushi 时自动重新出现。
///
/// - [both]：应用内与应用外都恢复——应用外球的关闭只管到下次打开 Fushi（冷启动
///   或切回前台）为止，不动「应用外显示」开关。
/// - [inApp]（出厂）：只有应用内球恢复（换页 / 回到 Fushi 即重现）；应用外球的
///   关闭等于关掉「应用外显示」。
/// - [off]：都不恢复——应用内球的关闭也等于关掉「应用内显示」，要到设置里重开。
enum FloatingBallAutoRestore {
  both('both'),
  inApp('in_app'),
  off('off');

  const FloatingBallAutoRestore(this.storageValue);

  final String storageValue;

  static const FloatingBallAutoRestore fallback = inApp;

  static FloatingBallAutoRestore fromStorage(Object? raw) {
    for (final FloatingBallAutoRestore value in values) {
      if (value.storageValue == raw) return value;
    }
    return fallback;
  }

  /// 关掉的应用内球在换页 / 回到 Fushi 时重现。
  bool get restoresInApp => this != off;

  /// 关掉的应用外球在打开 Fushi 时重新拉起（而不是关掉「应用外显示」）。
  bool get restoresSystem => this == both;
}
