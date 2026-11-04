/// 主屏小组件 / 控制中心控件 / Live Activity 点进 app 的深链。
///
/// 与图标快捷菜单同一个落地口：iOS 经 SceneDelegate → `url_events`，macOS 经
/// `source_urls` 事件流，最终都进 main.dart 的 `handleIncomingUrl`。Swift 侧的同名常量在
/// `fushi/apple/HomeWidgets/Extension/FushiHomeWidgetViews.swift`（`FushiLinks`），改形状
/// 两边一起改。
///
/// 已有的两条不在这里重复：查词入口复用 `fushi://shortcut/lookup`（`AppShortcut`），
/// 「今日一词」复用 `fushi://lookup?word=`（`lookupWordFromDeepLink`）。
sealed class HomeWidgetLink {
  const HomeWidgetLink();

  static const String _scheme = 'fushi';

  String get url;

  /// 不是本文件认得的链接返回 null（调用方按「未处理」放行给后面的分支）。
  static HomeWidgetLink? tryParse(String? value) {
    if (value == null) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.toLowerCase() != _scheme) return null;
    final String host = uri.host.toLowerCase();
    final List<String> segments = uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    switch (host) {
      case 'srs':
        return segments.length == 1 && segments.first == 'review'
            ? const HomeWidgetReviewLink()
            : null;
      case 'stats':
        return segments.isEmpty ? const HomeWidgetStatsLink() : null;
      case 'continue':
        if (segments.length != 1) return null;
        return HomeWidgetContinueLink(segments.first);
      case 'widget':
        if (segments.length != 1) return null;
        return switch (segments.first) {
          'camera_lookup' => const HomeWidgetCameraLookupLink(),
          'clipboard_lookup' => const HomeWidgetClipboardLookupLink(),
          'resume_audiobook' => const HomeWidgetResumeAudiobookLink(),
          _ => null,
        };
    }
    return null;
  }
}

/// 开始复习：有待复习的第一个顶层牌组直接进复习页，没有就落到复习 tab。
final class HomeWidgetReviewLink extends HomeWidgetLink {
  const HomeWidgetReviewLink();

  @override
  String get url => 'fushi://srs/review';
}

/// 统计中心。
final class HomeWidgetStatsLink extends HomeWidgetLink {
  const HomeWidgetStatsLink();

  @override
  String get url => 'fushi://stats';
}

/// 打开首页「继续」里的某一条：[key] 是首页给条目的稳定身份（`book:…` / `video:…` …），
/// 由首页按与点卡片完全相同的路径打开（`HomeWidgetContinueFeed`）。
final class HomeWidgetContinueLink extends HomeWidgetLink {
  const HomeWidgetContinueLink(this.key);

  final String key;

  @override
  String get url => 'fushi://continue/${Uri.encodeComponent(key)}';

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetContinueLink && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

final class HomeWidgetCameraLookupLink extends HomeWidgetLink {
  const HomeWidgetCameraLookupLink();

  @override
  String get url => 'fushi://widget/camera_lookup';
}

final class HomeWidgetClipboardLookupLink extends HomeWidgetLink {
  const HomeWidgetClipboardLookupLink();

  @override
  String get url => 'fushi://widget/clipboard_lookup';
}

/// 接着听：有活着的有声书会话就续播，否则打开最近那本（见 `HomeWidgetsHost`）。
final class HomeWidgetResumeAudiobookLink extends HomeWidgetLink {
  const HomeWidgetResumeAudiobookLink();

  @override
  String get url => 'fushi://widget/resume_audiobook';
}
