/// 悬浮球的场景、按钮目录与持久化编解码（设计见
/// `docs/specs/2026-09-28-floating-ball.md`）。
///
/// 设置 → 悬浮球 是唯一的配置入口：两个独立开关（应用内 / 应用外）+ 每个场景一组
/// 按钮勾选。页面只登记「本页能提供哪些按钮」（[FloatingBallScene]），显示哪些、
/// 按什么顺序由这里的目录与用户勾选决定。
library;

import 'package:fushi/src/reader/reader_control_layout.dart';

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

  /// 应用外：Android 原生系统球（别的 app 在前台时）。
  system('system');

  const FloatingBallScope(this.storageValue);

  final String storageValue;

  /// 本平台能配置的场景：应用外只有 Android 做得到（iOS 不允许应用外悬浮，
  /// 桌面没有这个概念）。
  static List<FloatingBallScope> availableOn({required bool isAndroid}) =>
      isAndroid
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

  /// 出厂按钮：阅读器是有声书的上一句 / 播放暂停 / 下一句（沿用旧阅读器内置球
  /// 的出厂槽位），漫画 / 视频是全部专属按钮；各场景都带全部全局按钮。
  List<String> get defaultButtons => <String>[
    ...switch (this) {
      reader => <String>[
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
  /// 输入框查词。
  lookup('lookup'),

  /// 读剪贴板查词。
  clipboard('clipboard'),

  /// 截屏 → 系统 OCR → 点字查词。
  screenOcr('screen_ocr');

  const FloatingBallGlobalAction(this.storageValue);

  final String storageValue;

  static FloatingBallGlobalAction? fromStorage(String raw) {
    for (final FloatingBallGlobalAction action in values) {
      if (action.storageValue == raw) return action;
    }
    return null;
  }

  /// 本平台有没有这个能力：截屏 OCR 只有 Android（MediaProjection）与 iOS
  /// （截自己的窗口）接了。
  bool availableOn({required bool isAndroid, required bool isIOS}) =>
      switch (this) {
        FloatingBallGlobalAction.screenOcr => isAndroid || isIOS,
        _ => true,
      };
}
