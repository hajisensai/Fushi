import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';

import 'package:fushi/src/anki/ankimobile_repository.dart'
    show fushiAnkiFetchCallback, fushiAnkiSuccessCallback;
import 'package:fushi/src/lookup/lookup_deep_link.dart';
import 'package:fushi/src/platform/app_shortcuts.dart';
import 'package:fushi/src/platform/widget_links.dart';

/// 外部投递进 app 的 `fushi://` 链接分哪几类。
///
/// main.dart 的 `handleIncomingUrl`（Android intent / iOS URL 事件 / macOS
/// `source_urls` 事件流）按 [FushiIncomingLink.classify] 的结果分流；macOS 的
/// `SourceUrlChannel` 也用同一个分类决定收不收。两边看的是同一份判据，
/// 「Dart 认得的链接」与「macOS 转交给 Dart 的链接」就不会各写一份、各自漏
/// （BUG：macOS 转交白名单漏了 `pair`，配对链接到不了 Dart）。
///
/// [host] 是该类链接的 `fushi://<host>`，原生侧（macOS `fushiRoutedUrlHosts`）
/// 只能按 host 判，由 `source_url_native_contract_test` 用每类的样例链接把
/// [host] 钉到真实解析器上、再与 Swift 字面量逐项对齐。
enum FushiIncomingLinkKind {
  /// `fushi://source?…`：卡片出处回跳。
  cardSource(host: 'source', routedByNativeShell: true),

  /// `fushi://pair?…`：互联配对（扫码 / NFC / 系统相机）。
  pair(host: FushiPairLink.host, routedByNativeShell: true),

  /// `fushi://shortcut/<id>`：主屏 / Dock 快捷方式。
  shortcut(host: 'shortcut', routedByNativeShell: true),

  /// `fushi://widget/…`：主屏小组件 / 菜单栏播放条。
  widget(host: 'widget', routedByNativeShell: true),

  /// `fushi://lookup?word=`：快捷指令 / 其它 app 发来的查词。
  lookup(host: 'lookup', routedByNativeShell: true),

  /// `fushi://auth/…`：OAuth 回调。macOS 上留给插件（`super`），不走 Dart 事件流。
  oauthRedirect(host: 'auth', routedByNativeShell: false),

  /// `fushi://ankiFetch`：AnkiMobile 回调（iOS 专属）。
  ankiFetch(host: 'ankifetch', routedByNativeShell: false),

  /// `fushi://ankiSuccess`：AnkiMobile 回调（iOS 专属）。
  ankiSuccess(host: 'ankisuccess', routedByNativeShell: false);

  const FushiIncomingLinkKind({
    required this.host,
    required this.routedByNativeShell,
  });

  /// 小写 host。
  final String host;

  /// macOS 原生壳是否把这类链接交给 Dart 的 `source_urls` 事件流。`false` 的
  /// （OAuth / AnkiMobile 回调）照旧交给各自的插件。
  final bool routedByNativeShell;
}

/// 一条已分类、已用对应解析器校验过的外部 `fushi://` 链接。
sealed class FushiIncomingLink {
  const FushiIncomingLink();

  FushiIncomingLinkKind get kind;

  /// 按 `handleIncomingUrl` 一贯的优先顺序逐个试解析器；都不认返回 `null`。
  static FushiIncomingLink? classify(String data) {
    final Uri? uri = Uri.tryParse(data);
    if (uri != null && uri.scheme == 'fushi' && uri.host == 'source') {
      return CardSourceIncomingLink(data);
    }
    if (FushiPairLink.tryParse(data) != null) return PairIncomingLink(data);
    final AppShortcut? shortcut = AppShortcut.tryParse(data);
    if (shortcut != null) return ShortcutIncomingLink(shortcut);
    final WidgetLink? widgetLink = WidgetLink.tryParse(data);
    if (widgetLink != null) return WidgetIncomingLink(widgetLink);
    final String? word = lookupWordFromDeepLink(data);
    if (word != null) return LookupIncomingLink(word);
    final String normalized = data.toLowerCase();
    if (normalized.startsWith('fushi://auth/')) {
      return OAuthRedirectIncomingLink(data);
    }
    if (normalized.startsWith(fushiAnkiFetchCallback.toLowerCase())) {
      return const AnkiFetchIncomingLink();
    }
    if (normalized.startsWith(fushiAnkiSuccessCallback.toLowerCase())) {
      return AnkiSuccessIncomingLink(data);
    }
    return null;
  }
}

final class CardSourceIncomingLink extends FushiIncomingLink {
  const CardSourceIncomingLink(this.url);
  final String url;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.cardSource;
}

final class PairIncomingLink extends FushiIncomingLink {
  const PairIncomingLink(this.url);
  final String url;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.pair;
}

final class ShortcutIncomingLink extends FushiIncomingLink {
  const ShortcutIncomingLink(this.shortcut);
  final AppShortcut shortcut;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.shortcut;
}

final class WidgetIncomingLink extends FushiIncomingLink {
  const WidgetIncomingLink(this.link);
  final WidgetLink link;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.widget;
}

final class LookupIncomingLink extends FushiIncomingLink {
  const LookupIncomingLink(this.word);
  final String word;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.lookup;
}

final class OAuthRedirectIncomingLink extends FushiIncomingLink {
  const OAuthRedirectIncomingLink(this.url);
  final String url;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.oauthRedirect;
}

final class AnkiFetchIncomingLink extends FushiIncomingLink {
  const AnkiFetchIncomingLink();
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.ankiFetch;
}

final class AnkiSuccessIncomingLink extends FushiIncomingLink {
  const AnkiSuccessIncomingLink(this.url);
  final String url;
  @override
  FushiIncomingLinkKind get kind => FushiIncomingLinkKind.ankiSuccess;
}
