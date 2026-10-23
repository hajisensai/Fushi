import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/web/web_comic_reader_launch.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 网页漫画：「用 Fushi 阅读本章」扫当前页的漫画图交给漫画阅读器（从旧单页浏览
/// 页迁来，行为不变），外加「网页漫画广告过滤」开关。
///
/// 合规：只在 [webComicReaderActionAvailable]（`onlineMangaSource` 合规门）为真时
/// 装配——iOS 上浏览器照常可用，只是没有这项动作。扫图执行器整条只在门开时建。
class WebComicFeature extends WebBrowserFeature {
  WebComicFeature({required WidgetRef ref})
    : _ref = ref,
      _scanDriver = webComicReaderActionAvailable()
          ? WebComicScanDriver()
          : null;

  final WidgetRef _ref;
  final WebComicScanDriver? _scanDriver;

  /// 正在扫图的标签页（防连点）。
  final Set<String> _scanning = <String>{};

  @override
  String get id => 'web_comic';

  @override
  bool get available => _scanDriver != null;

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    _scanDriver?.attach(controller);
  }

  @override
  void onTabClosed(WebBrowserTab tab) => _scanning.remove(tab.id);

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    final WebComicScanDriver? driver = _scanDriver;
    if (driver == null) return const <WebBrowserAction>[];
    final AppModel appModel = _ref.read(appProvider);
    final bool canRead = tab.controller != null && tab.url != null;
    final bool adFilter = appModel.prefsRepo.webComicAdFilter;
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'web_comic_read_chapter',
        icon: FushiIcons.manga,
        label: t.manga_web_chapter_read,
        placement: WebBrowserActionPlacement.toolbar,
        priority: 70,
        selected: _scanning.contains(tab.id),
        onPressed: canRead && !_scanning.contains(tab.id)
            ? () => unawaited(_readChapter(context, tab, driver))
            : null,
      ),
      WebBrowserAction(
        id: 'web_comic_ad_filter',
        icon: FushiIcons.webAssetOff,
        label: adFilter ? t.manga_web_ad_filter_on : t.manga_web_ad_filter_off,
        selected: adFilter,
        onPressed: () =>
            unawaited(appModel.prefsRepo.setWebComicAdFilter(!adFilter)),
      ),
    ];
  }

  Future<void> _readChapter(
    BuildContext context,
    WebBrowserTab tab,
    WebComicScanDriver driver,
  ) async {
    final InAppWebViewController? controller = tab.controller;
    final Uri? url = tab.url;
    if (controller == null || url == null || !_scanning.add(tab.id)) return;
    FushiToast.show(msg: t.manga_web_scan_running);
    try {
      final WebComicScanResult scan = await driver.scan(
        controller,
        pageUrl: url,
      );
      if (!context.mounted) return;
      if (scan.isEmpty) {
        FushiToast.show(
          msg: t.manga_web_scan_empty,
          severity: ToastSeverity.warning,
        );
        return;
      }
      await openWebComicScanInReader(context: context, ref: _ref, scan: scan);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebComicFeature.readChapter', error, stack);
      FushiToast.show(
        msg: t.manga_web_scan_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      _scanning.remove(tab.id);
    }
  }
}
