import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2930 导入页统一（2026-08-18 用户反馈）源码守卫：
///
/// 1. 四个模块导入页的**页头不再有「添加来源」**——添加入口收敛到「常驻来源」
///    区头（Cupertino 布局不渲染页头，收敛后 iOS 才第一次有了这个入口）；
/// 2. 快速导入区统一为「导入单件 + 导入文件夹」（游戏无扫描根概念，只有单件
///    入口，见 `home_game_page.dart` 的 `_buildImport` 文档）；
/// 3. 「本地扫描根」与「常驻来源」两个叫法统一为「常驻来源」
///    （`media_source_section_title`），`media_source_local_roots` key 已删除。
///
/// 为什么用源码扫描：`MediaSourcesPage` / `MangaSourcesPage` 都从 `appProvider`
/// 拿整个 `AppModel`，widget 测试测的是环境不是接线；这里要守的恰恰是接线与
/// 入口位置本身。读源码并**掩掉注释**（共享 [maskComments]，等长掩码不打乱
/// 下标），防止「实现删光、注释里留字面量」的假绿。
String _read(String path) => maskComments(File(path).readAsStringSync());

/// 从 [signature] 起，到下一个同缩进 `Widget ` 成员声明为止的方法切片。
String _methodSlice(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final int end = source.indexOf('\n  Widget ', start + signature.length);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

void main() {
  final String page = _read(
    'lib/src/pages/implementations/media_sources_page.dart',
  );
  final String view = _read(
    'lib/src/pages/implementations/media_sources_view.dart',
  );
  final String manga = _read('lib/src/media/manga/manga_sources_page.dart');
  final String game = _read(
    'lib/src/pages/implementations/home_game_page.dart',
  );

  group('页头不再有「添加来源」，入口在常驻来源区头', () {
    test('书 / 视频导入页', () {
      expect(
        _methodSlice(page, 'Widget _buildHeader()'),
        isNot(contains('t.media_source_add')),
        reason: '页头只留视频的刮削、清理记录与后台任务',
      );
      expect(
        _methodSlice(page, 'Widget _buildSourcesSectionHeader()'),
        contains('tooltip: t.media_source_add'),
        reason: '区块内必须有等价的添加入口，能力不丢',
      );
    });

    test('漫画导入页', () {
      expect(
        _methodSlice(manga, 'Widget _buildHeader()'),
        isNot(contains('t.media_source_add')),
      );
      // 区头行：标题 + 添加按钮挂同一个 Row（build 里唯一一处 media_source_add）。
      expect(manga, contains('tooltip: t.media_source_add'));
      expect(
        manga.indexOf('tooltip: t.media_source_add'),
        greaterThan(manga.indexOf('t.media_source_section_title')),
        reason: '添加按钮必须在「常驻来源」区头，不在页头',
      );
    });
  });

  group('快速导入区统一为「导入单件 + 导入文件夹」', () {
    test('书 / 视频两域都有导入文件夹入口', () {
      // book 与 video 两个 case 各接一次共享 _importFolder。
      expect(
        RegExp('onTap: _importFolder').allMatches(page).length,
        2,
        reason: 'book / video 各一个「导入文件夹」按钮',
      );
      final int videoCase = page.indexOf("'video' => <QuickImportAction>[");
      expect(videoCase, isNonNegative);
      expect(
        page.indexOf('onTap: _importFolder', videoCase),
        greaterThan(videoCase),
        reason: '视频不再只有「导入视频」一个按钮（TODO-2930）',
      );
    });

    test('第三方备份导入只在设置里，不进书的快速导入区', () {
      // 用户 2026-09-28：`.hoshi` 等第三方书库备份导入只保留设置 › 同步与
      // 备份的「第三方导入」入口，书的导入页不再并排一个按钮。
      expect(page, isNot(contains('t.hoshi_import_entry')));
      expect(page, isNot(contains('ExternalReaderImportPage')));
      expect(
        _read('lib/src/sync/sync_settings_schema.dart'),
        contains('ExternalReaderImportPage'),
        reason: '设置里的入口必须还在',
      );
    });

    test('漫画接同一个共享 importFolder 流程', () {
      expect(manga, contains('.importFolder()'));
    });

    test('游戏保留单件入口（无扫描根概念，无文件夹管线）', () {
      // M3E 拖放区卡片里的主按钮（不再经共享 QuickImportSection 的 tonal 钮）。
      expect(game, contains('label: Text(t.game_add)'));
      expect(game, contains('addGameViaFilePicker'));
    });

    test('共享 importFolder 按域出「设为常驻来源」提示语', () {
      expect(view, contains('Future<void> importFolder()'));
      expect(view, contains('t.video_import_folder_as_source_hint'));
      expect(view, contains('t.manga_import_folder_as_source_hint'));
      expect(view, contains('t.book_import_folder_as_source_hint'));
    });
  });

  /// 2026-09-19 用户口径：「统一一下视频和动画的导入页，重新设计一下对源和仓库的
  /// UI」——当时落地为两页顶部同一条分段选择器（本地 / 仓库 / 扩展 / 在线源）。
  ///
  /// 2026-09-27 起在线来源 / 扩展 / 仓库整体搬进顶层「浏览」模块（Mihon Browse
  /// 形态，`browse_page.dart` 的来源 / 扩展页签 + `browse_online_sources_view.dart`），
  /// 导入页只剩本地来源。本组钉的是这次收拢不被回退：导入页不再长出在线入口，
  /// 在线来源面只有浏览模块一份。
  group('导入页只剩本地来源，在线源 / 扩展只住在浏览模块', () {
    final String online = _read(
      'lib/src/pages/implementations/browse_online_sources_view.dart',
    );
    final String mangaOnline = _read(
      'lib/src/media/manga/manga_online_sources_view.dart',
    );
    final String browse = _read(
      'lib/src/pages/implementations/browse_page.dart',
    );

    test('两页本地段都是快速导入 + 常驻来源，不再挂分段选择器', () {
      for (final String source in <String>[page, manga]) {
        expect(source, isNot(contains('ImportPageSegmentBar(')));
        expect(source, contains('Widget _buildLocalSegment()'));
        final String local = _methodSlice(
          source,
          'Widget _buildLocalSegment()',
        );
        expect(local, contains('QuickImportSection('));
        expect(local, contains('MediaSourcesView('));
      }
    });

    test('导入页不再挂扩展 / 在线源组件', () {
      for (final String source in <String>[page, manga]) {
        expect(source, isNot(contains('MihonExtensionsPage(')));
        expect(source, isNot(contains('MihonInstalledSourcesSection(')));
        expect(source, isNot(contains('LnReaderExtensionsSection(')));
        expect(source, isNot(contains('LnReaderInstalledSourcesSection(')));
      }
    });

    test('视频源扩展内嵌在浏览模块里，独立页与入口卡已删', () {
      expect(online, contains('MihonExtensionsPage('));
      expect(online, contains('MihonInstalledSourcesSection('));
      expect(online, contains('onOpenSource: _openAnimeSource'));
      expect(online, isNot(contains('VideoOnlineSourcesPage')));
      expect(online, isNot(contains('video_online_sources_entry')));
      expect(
        File(
          'lib/src/media/video/online/video_online_sources_page.dart',
        ).existsSync(),
        isFalse,
        reason: '独立页已并入浏览模块；再长出来就是又分叉了',
      );
    });

    test('扩展节 widget key 固定、浏览页按域保活，切页签 / 切域不丢状态', () {
      expect(
        online,
        contains(
          r"ValueKey<String>('video_mihon_extensions_${widget.section.name}')",
        ),
      );
      expect(
        mangaOnline,
        contains(r"ValueKey<String>('manga_mihon_extensions_${section.name}')"),
      );
      // 各域是可横滑的 TabBarView 页，经 _BrowseTabKeepAlive 保活（离屏不丢状态）。
      expect(browse, contains('_BrowseSwipeSections<OnlineSourcesDomain>('));
      expect(browse, contains(r"'browse-${tab.name}-${domain.name}'"));
      expect(browse, contains('bool get wantKeepAlive => true;'));
    });

    test('漫画在线源与小说 / 视频一样点行进源（mokuro.moe 行进目录）', () {
      expect(mangaOnline, contains('MihonInstalledSourcesSection('));
      expect(mangaOnline, contains('onOpenSource: _openMihonSource'));
      expect(mangaOnline, contains('MihonSourceBrowsePage('));
      expect(
        'MokuroMoeSourceRow(onOpen: _openMokuro)'.allMatches(mangaOnline),
        hasLength(2),
        reason: '有 / 无 Mihon 宿主两条分支里的 mokuro.moe 行都要能点进目录',
      );
    });

    test('来源 / 扩展 / 发现 / 下载的二级选择是标签页，不再是分段按钮', () {
      expect(browse, isNot(contains('FushiSegmentedStrip')));
      expect(browse, isNot(contains('ButtonSegment<')));
      expect(
        RegExp(
          r'_BrowseSwipeSections<(?:OnlineSourcesDomain|_DownloadsResourceDomain|BrowseDownloadsSection)>\(',
        ).allMatches(browse),
        hasLength(3),
        reason: '来源 / 扩展共用一处 + 发现 + 下载，共三处二级标签条',
      );
      // One additional generic constructor belongs only to the explicit
      // widget-test seam. Keep a total budget so new production domains cannot
      // silently escape the typed-site assertions above.
      expect(
        RegExp(r'_BrowseSwipeSections<\w+>\(').allMatches(browse),
        hasLength(4),
      );
      final String seam = methodBody(
        browse,
        'Widget debugBrowseSwipeSections<',
      );
      expect(
        RegExp(r'_BrowseSwipeSections<T>\(').allMatches(seam),
        hasLength(1),
      );
      expect(
        'secondary: true'.allMatches(browse),
        hasLength(1),
        reason: '三处二级标签条共用 _BrowseSwipeSections 里同一份 secondary tabs',
      );
      for (final String key in <String>[
        r"'browse-${tab.name}-domain-picker'",
        "'downloads-resource-type-picker'",
        "'browse-downloads-section-picker'",
      ]) {
        expect(browse, contains(key), reason: '二级标签条保留稳定 key：$key');
      }
    });
  });

  group('术语统一：「本地扫描根」并入「常驻来源」', () {
    test('漫画区头改用 media_source_section_title，旧 key 全灭', () {
      expect(manga, contains('t.media_source_section_title'));
      expect(manga, isNot(contains('media_source_local_roots')));
    });

    test('i18n 里 media_source_local_roots key 已删除', () {
      final String zh = File(
        'lib/i18n/strings_zh-CN.i18n.json',
      ).readAsStringSync();
      final String en = File('lib/i18n/strings.i18n.json').readAsStringSync();
      expect(zh, isNot(contains('media_source_local_roots')));
      expect(en, isNot(contains('media_source_local_roots')));
      expect(zh, isNot(contains('本地扫描根')));
    });
  });
}
