import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 用户口径守卫（PR#594 落地形态）：
///
/// 1. 漫画库顶层**恒为三视图**，Mihon 扩展不占 tab —— 由
///    `manga_library_page_split_test.dart` 守；
/// 2. **扩展管理挂在「来源」视图里**（本文件）；
/// 3. **iOS / Linux 与其它平台导航结构相同**，差异只在各视图内部内容（本文件）。
///
/// 第 2、3 条为什么用源码扫描而不是 widget 测试：`MangaSourcesPage` /
/// `MangaBrowsePage` 都从 `appProvider` 拿 `AppModel`（整库 + WebView + 一堆
/// provider），挂起来测的是环境不是接线；而这两条要守的恰恰是**接线本身**。
/// 内嵌节真能在外层 ListView 里渲染这件事，由
/// `test/media/manga/mihon_extensions_page_test.dart` 的 embedded 用例真 pump 守。
String _read(List<String> parts) =>
    File(p.joinAll(<String>['lib', 'src', 'media', 'manga', ...parts]))
        .readAsStringSync();

void main() {
  group('漫画「来源」视图组成', () {
    late String sources;

    setUp(() {
      sources = _read(<String>['manga_sources_page.dart']);
    });

    test('本地扫描根这一节仍是漫画种类的 MediaSourcesView（没接成 book）', () {
      expect(sources, contains('MediaSourcesView('));
      expect(sources, contains("mediaKind: 'manga'"));
    });

    test('Mihon 扩展管理内嵌在「来源」视图里，不是另一个顶层 tab', () {
      expect(
        sources,
        contains('MihonExtensionsPage(embedded: true)'),
        reason: '用户口径：漫画扩展就是来源，必须收进「来源」视图当一节',
      );
    });

    test('扩展提供的在线来源设置也在同一视图内', () {
      expect(sources, contains('_buildOnlineSource('));
      expect(sources, contains('t.mihon_sources_title'));
    });
  });

  group('iOS / Linux 导航结构与其它平台相同', () {
    test('「来源」视图在扩展宿主不可用时降级内容，而不是不存在', () {
      final String sources = _read(<String>['manga_sources_page.dart']);
      // AppModel.mihonManager 在 iOS/Linux 抛 UnsupportedError：读它之前必须有门。
      expect(
        sources,
        contains('if (!MihonRuntimeFactory.isSupported) return;'),
        reason: '不设门就会在 iOS/Linux 上抛 UnsupportedError，视图直接白屏',
      );
      expect(
        sources,
        contains('t.mihon_runtime_unavailable'),
        reason: '不支持的平台要显示「此平台暂不支持」，而不是空白或崩溃',
      );
    });

    test('「浏览」视图恒有 mokuro.moe，Mihon 在线源与它并列', () {
      final String browse = _read(<String>['manga_browse_page.dart']);
      expect(
        browse,
        contains('if (!MihonRuntimeFactory.isSupported) return;'),
        reason: '同上：iOS/Linux 上不得触碰 AppModel.mihonManager',
      );
      expect(
        browse,
        contains('t.mihon_source_browse_mokuro'),
        reason: 'mokuro.moe 是内置来源，任何平台都必须在「浏览」里',
      );
      expect(
        browse,
        contains('MihonSourceBrowsePage('),
        reason: '已启用的 Mihon 在线源要能从「浏览」直接进内容，不是只在设置里躺着',
      );
    });
  });
}
