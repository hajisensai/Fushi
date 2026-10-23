import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_reader_launch.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 网页小说：「用 Fushi 阅读（小说）」把当前页整页 HTML 交给 Rust 提取正文、并进
/// 连载会话，预览确认后进书架并在阅读器打开（从旧单页浏览页迁来，行为不变）。
///
/// 合规：只在 [webNovelReaderActionAvailable]（`onlineNovelSource` 合规门）为真时
/// 装配。
class WebNovelFeature extends WebBrowserFeature {
  WebNovelFeature({required WidgetRef ref})
    : _ref = ref,
      _novelAvailable = webNovelReaderActionAvailable();

  final WidgetRef _ref;
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
    final bool busy = _extracting.contains(tab.id);
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'web_novel_read',
        icon: FushiIcons.books,
        label: t.novel_web_page_read,
        placement: WebBrowserActionPlacement.toolbar,
        priority: 60,
        selected: busy,
        onPressed: tab.controller != null && tab.url != null && !busy
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
