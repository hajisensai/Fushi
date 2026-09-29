/// 全局悬浮球的模式与全局按钮（设计见 `docs/specs/2026-09-28-floating-ball.md`）。
library;

/// 悬浮球常驻在哪里。
enum FloatingBallMode {
  /// 不显示全局球；阅读器旧的内置球按它自己的开关工作。
  off('off'),

  /// Flutter 悬浮球挂在根 builder 上，任何页面都在。五端通用。
  inApp('in_app'),

  /// Android 原生悬浮窗，在别的 app 上面也在；Fushi 自己在前台时由 Flutter
  /// 球接管（场景按钮只有 Flutter 侧拿得到）。
  system('system');

  const FloatingBallMode(this.storageValue);

  final String storageValue;

  static FloatingBallMode fromStorage(String raw) {
    for (final FloatingBallMode mode in values) {
      if (mode.storageValue == raw) return mode;
    }
    return off;
  }

  /// 本平台能选的模式：系统常驻只有 Android 做得到（iOS 不允许应用外悬浮，
  /// 桌面没有这个概念）。
  static List<FloatingBallMode> availableOn({required bool isAndroid}) =>
      isAndroid ? values : const <FloatingBallMode>[off, inApp];

  /// 持久化值在本平台上的实际效果：非 Android 读到 [system]（例如备份从
  /// Android 恢复）按 [inApp] 处理，而不是让球凭空消失。
  FloatingBallMode effectiveOn({required bool isAndroid}) =>
      this == system && !isAndroid ? inApp : this;

  /// 应用内要不要画 Flutter 球。系统模式下 app 在前台时也画（原生球此时隐藏）。
  bool get showsInAppBall => this != off;
}

/// 不随场景变化、每个页面都有的按钮。
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

  /// 逗号分隔的持久化值 → 按钮列表（保持枚举顺序、去掉未知值与重复）。
  /// 空串 = 从没设过 → 全开；用户全部关掉存的是 `-`。
  static List<FloatingBallGlobalAction> decodeList(String raw) {
    if (raw.isEmpty) return values;
    final Set<String> ids = raw.split(',').map((String s) => s.trim()).toSet();
    return <FloatingBallGlobalAction>[
      for (final FloatingBallGlobalAction action in values)
        if (ids.contains(action.storageValue)) action,
    ];
  }

  static String encodeList(Iterable<FloatingBallGlobalAction> actions) {
    final Set<FloatingBallGlobalAction> set = actions.toSet();
    if (set.isEmpty) return '-';
    return <String>[
      for (final FloatingBallGlobalAction action in values)
        if (set.contains(action)) action.storageValue,
    ].join(',');
  }
}
