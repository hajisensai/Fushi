/// 悬浮球的场景、按钮目录与持久化编解码（设计见
/// `docs/specs/2026-09-28-floating-ball.md`）。
///
/// 设置 → 悬浮球 是唯一的配置入口：两个独立开关（应用内 / 应用外）+ 每个场景一组
/// 按钮勾选。页面只登记「本页能提供哪些按钮」（[FloatingBallScene]），显示哪些、
/// 按什么顺序由这里的目录与用户勾选决定。
library;

import 'dart:io' show Platform;

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
  /// 沿用旧阅读器内置球的出厂槽位），漫画 / 视频是全部专属按钮；各场景都带全部
  /// 全局按钮。
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
      action.storageValue,
  ];

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
  cameraOcr('camera_ocr');

  const FloatingBallGlobalAction(this.storageValue);

  final String storageValue;

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
  /// 路径），截屏识字 / 拍照查词桌面不提供；其余场景同 [availableOn]。
  ///
  /// [lookupModuleEnabled]：「查词」模块开着没有。桌面应用外球的「查词」（打开
  /// 查词页）与「应用外查词」（全局查词覆盖窗）都挂在这个模块上——模块关着时查词
  /// 页没有入口、全局查词也不启动，按钮点了没反应，所以干脆不出现。剪贴板查词在
  /// 覆盖窗不可用时退回主窗查词弹窗，不受影响。
  bool availableIn(
    FloatingBallScope scope, {
    required bool isAndroid,
    required bool isIOS,
    required bool isDesktop,
    required bool lookupModuleEnabled,
  }) {
    if (scope == FloatingBallScope.system && isDesktop) {
      return switch (this) {
        FloatingBallGlobalAction.lookup ||
        FloatingBallGlobalAction.popupLookup => lookupModuleEnabled,
        FloatingBallGlobalAction.clipboard => true,
        FloatingBallGlobalAction.screenOcr ||
        FloatingBallGlobalAction.cameraOcr => false,
      };
    }
    return availableOn(isAndroid: isAndroid, isIOS: isIOS);
  }
}
