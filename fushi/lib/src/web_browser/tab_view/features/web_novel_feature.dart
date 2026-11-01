import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_reader_launch.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_open_in_fushi_action.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_page_content.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 网页小说：「用 Fushi 阅读」把当前页整页 HTML 交给 Rust 提取正文、并进连载会话，预览确认
/// 后进书架并在阅读器打开（从旧单页浏览页迁来）。入口走统一的 [webOpenInFushiAction]：
/// [pageContent] 探出这页是小说正文时上工具栏，否则以「作为小说用 Fushi 阅读」收在「⋯」里。
///
/// 合规：只在 [webNovelReaderActionAvailable]（`onlineNovelSource` 合规门）为真时
/// 装配。
class WebNovelFeature extends WebBrowserFeature {
  WebNovelFeature({required WidgetRef ref, WebPageContentFeature? pageContent})
    : _ref = ref,
      _pageContent = pageContent,
      _novelAvailable = webNovelReaderActionAvailable();

  final WidgetRef _ref;
  final WebPageContentFeature? _pageContent;
  final bool _novelAvailable;

  /// 正在提取的标签页（防连点）。
  final Set<String> _extracting = <String>{};

  @override
  String get id => 'web_novel';

  @override
  bool get available => _novelAvailable;

  @override
  void onTabClosed(WebBrowserTab tab) => _extracting.remove(tab.id);

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    if (!_novelAvailable) return const <WebBrowserAction>[];
    // 视频观看页（YouTube 等）没有小说正文可提取：不出「阅读（小说）」。
    if (isWebBrowserVideoWatchPage(tab.url)) return const <WebBrowserAction>[];
    final bool busy = _extracting.contains(tab.id);
    return <WebBrowserAction>[
      webOpenInFushiAction(
        kind: WebPageContentKind.novel,
        primary: _pageContent?.kindOf(tab) == WebPageContentKind.novel,
        busy: busy,
        onPressed: tab.controller != null && tab.url != null
            ? () => unawaited(_read(context, tab))
            : null,
      ),
    ];
  }

  Future<void> _read(BuildContext context, WebBrowserTab tab) async {
    final InAppWebViewController? controller = tab.controller;
    final Uri? url = tab.url;
    if (!_novelAvailable ||
        controller == null ||
        url == null ||
        !_extracting.add(tab.id)) {
      return;
    }
    FushiToast.show(msg: t.novel_web_extract_running);
    try {
      await readWebNovelPageInFushi(
        context: context,
        ref: _ref,
        controller: controller,
        pageUrl: url,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebNovelFeature.read', error, stack);
      FushiToast.show(
        msg: t.novel_web_extract_failed(error: '$error'),
        severity: ToastSeverity.error,
      );
    } finally {
      _extracting.remove(tab.id);
    }
  }
}
