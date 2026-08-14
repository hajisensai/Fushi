import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

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
/// 读源码并**掩掉注释**（共享 `maskComments`，等长掩码不打乱下标）。
///
/// 本文件全是「必须包含 X」型断言，不掩注释的话，把实现删光、只在注释里留下那串
/// 字面量就能骗绿——这是本仓真实抓到过的假绿形态。
String _read(List<String> parts) => maskComments(
      File(p.joinAll(<String>['lib', 'src', 'media', 'manga', ...parts]))
          .readAsStringSync(),
    );

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

    test('macOS 的「来源」视图有 Aidoku 单包与仓库导入入口', () {
      expect(sources, contains("allowedExtensions: const <String>['aix']"));
      expect(sources, contains("ValueKey<String>('aidoku_import_aix')"));
      expect(sources, contains("ValueKey<String>('aidoku_add_repository')"));
      expect(sources, contains("ValueKey<String>('aidoku_repository_url')"));
      expect(sources, contains('AidokuPackageStore.open()'));
      expect(sources, contains('AidokuRepositoryStore.open()'));
      expect(sources, contains('_AidokuRepositorySourcesDialog('));
      expect(sources, contains('MangaExtensionManagementTile('));
    });

    test('Aidoku 仓库 URL 输入框使用 Material 对话框', () {
      final int start = sources.indexOf(
        'class _AidokuRepositoryUrlDialogState',
      );
      final int end = sources.indexOf(
        'class _AidokuRepositorySourcesDialog',
      );
      expect(start, isNonNegative);
      expect(end, greaterThan(start));

      final String dialogSource = sources.substring(start, end);
      expect(dialogSource, contains('=> AlertDialog('));
      expect(dialogSource, isNot(contains('AlertDialog.adaptive(')));
    });

    test('扩展提供的在线来源设置也在同一视图内', () {
      expect(sources, contains('_buildOnlineSource('));
      expect(sources, contains('t.mihon_sources_title'));
    });

    // BUG-1431，用户口径：「mokuro 不应该单独显示，应该和漫画扩展同一层级」。
    // 它此前是「本地扫描根」一节里的一行（和 Hibiki 互联并排），但它是个网站。
    test('mokuro.moe 归「漫画源」一节，不再挂在本地扫描根下', () {
      expect(sources, contains('MokuroMoeSourceRow()'));
      expect(
        sources.indexOf('MokuroMoeSourceRow()'),
        greaterThan(sources.indexOf('t.mihon_sources_title')),
        reason: '它必须排在「漫画源」小标题之后，与扩展提供的在线源同节',
      );
      final String localRoots = maskComments(
        File(p.join('lib', 'src', 'pages', 'implementations',
                'media_sources_view.dart'))
            .readAsStringSync(),
      );
      expect(
        localRoots,
        isNot(contains('Mokuro')),
        reason: '共享的扫描根视图（书/视频/漫画三域共用）里不得再出现在线站点',
      );
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
      expect(
        browse,
        contains('AidokuSourceBrowsePage('),
        reason: '安装的 Aidoku 源也要从「浏览」直接进入内容目录',
      );
      expect(
        browse,
        contains('AidokuPackageStore.changes.listen'),
        reason: '保活的「浏览」页必须在安装、卸载或启停后立即重载 Aidoku 源',
      );
      // BUG-1431：mokuro.moe 与扩展源遵守同一条可见性规则——「来源」里关掉的源
      // 不出现在「浏览」里。以前它那个开关只让目录页显示成禁用态，行照旧列着。
      expect(
        browse,
        contains('isMokuroMoeSourceEnabled('),
        reason: '「浏览」必须尊重「来源」里的 mokuro.moe 开关，否则同一节两种开关语义',
      );
    });
  });

  /// 用户口径：「删掉漫画里面的标题，管理来源、浏览这两个」。
  ///
  /// 这两个页面此前用的是 `FushiPageHeader(title: ..., bottom: navigation)`
  /// ——页头先渲染一行页面大标题，再把库页视图导航条挂在它下面。可导航条本身就
  /// 标明了当前在哪个视图，那行标题纯属重复占一行高度。通用媒体来源页
  /// (`MediaSourcesPage._buildHeader`) 早已迁到 `customTitle` 范式（导航条直接占
  /// 页头主位），漫画这两个页是漏迁的，所以比别处多出一行。
  ///
  /// 守的是**形态**不是文案：只要还有 `bottom: widget.navigation`，就说明又退回
  /// 了「标题在上、导航条在下」的两行结构。
  group('漫画来源 / 浏览页头不再渲染重复的页面大标题', () {
    for (final (String label, String file) in <(String, String)>[
      ('来源', 'manga_sources_page.dart'),
      ('浏览', 'manga_browse_page.dart'),
    ]) {
      test('$label 页：有导航条时它占页头主位（customTitle）', () {
        final String source = _read(<String>[file]);
        expect(
          source,
          contains('FushiPageHeader.customTitle('),
          reason: '导航条必须直接占页头主位，而不是挂在一行大标题下面',
        );
      });

      test('$label 页：不再把导航条挂成页头的 bottom', () {
        final String source = _read(<String>[file]);
        expect(
          source,
          isNot(contains('bottom: widget.navigation')),
          reason: 'bottom 形态就意味着上方还留着那行被用户要求删掉的大标题',
        );
      });
    }
  });
}
