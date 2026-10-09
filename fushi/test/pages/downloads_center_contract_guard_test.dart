import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String _downloadsPath = 'lib/src/pages/implementations/browse_page.dart';
const String _downloadActionsPath =
    'lib/src/pages/implementations/download_actions.dart';

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: '守卫语料文件不存在：$path');
  return file.readAsStringSync();
}

void main() {
  test('BUG-1956：浏览页保留来源、扩展、发现、下载四个顶层页签', () {
    // 2026-09-27 起「下载」模块改名「浏览」（Mihon Browse 形态）：原「资源」页签
    // 变成「发现」，任务 / 订阅收进「下载」页签的两段，设置改成页头齿轮 push 的
    // 独立页。页签用枚举而不是下标（随平台 / 模块开关增减时不落错页）。
    final String source = _read(_downloadsPath);
    final String code = maskCommentsAndScriptLines(source);
    final String structural = maskCommentsAndStrings(source);

    expect(
      code,
      contains('enum BrowseTab { discover, sources, extensions, downloads }'),
      reason: '浏览页顶层只能有且必须有四个目的地，顺序即页头顺序',
    );
    // 2026-09-28 用户拍板：发现排第一（打开浏览默认落在发现）。页头顺序由
    // _visibleTabs 的列表字面量决定，枚举顺序只是文档；两处都钉住。
    expect(
      compactCode(methodBody(source, 'List<BrowseTab> _visibleTabs(')),
      contains(
        '[if(discover)BrowseTab.discover,if(online)BrowseTab.sources,'
        'if(online)BrowseTab.extensions,BrowseTab.downloads,]',
      ),
      reason: '浏览页签顺序：发现 → 来源 → 扩展 → 下载',
    );
    final String labels = compactCode(methodBody(source, 'String _tabLabel('));
    for (final String label in <String>[
      'BrowseTab.sources=>t.media_import_segment_sources,',
      'BrowseTab.extensions=>t.media_import_segment_extensions,',
      'BrowseTab.discover=>t.library_view_discover,',
      'BrowseTab.downloads=>t.nav_downloads,',
    ]) {
      expect(labels, contains(label), reason: '页签文案缺失：$label');
    }
    expect(
      code,
      isNot(contains('LibrarySectionTab<int>')),
      reason: '页签不得退回整数下标',
    );

    expect(
      code,
      contains('enum BrowseDownloadsSection { tasks, subscriptions }'),
      reason: '「下载」页签必须保留任务 / 订阅两段',
    );
    expect(
      code,
      contains("'browse-downloads-section-picker'"),
      reason: '任务 / 订阅标签条必须有稳定 key，便于焦点导航与行为验证',
    );

    // 页签控制器由本页持有（按页签 id 落回选中，PR #1707 审查），同一个控制器
    // 驱动页头页签与 TabBarView。
    expect(identifierCall('TabController').hasMatch(structural), isTrue);
    expect(identifierCall('TabBarView').hasMatch(structural), isTrue);
    expect(
      identifierCall('VideoDownloadJobsPanel').hasMatch(structural),
      isTrue,
      reason: '任务段不得再被从下载中心拆掉',
    );
    expect(
      identifierCall('VideoDownloadSubscriptionsPanel').hasMatch(structural),
      isTrue,
      reason: '订阅段不得再被从下载中心拆掉',
    );

    // 设置：独立页 BrowseDownloadSettingsPage，入口是「下载」页签页头的齿轮。
    final String settingsPage = source.substring(
      source.indexOf('class BrowseDownloadSettingsPage '),
    );
    expect(
      identifierCall('TorrentSettingsSection').hasMatch(settingsPage),
      isTrue,
      reason: '下载设置页不得再被从浏览模块拆掉',
    );
    expect(code, contains("'browse-download-settings'"));
    expect(
      compactCode(methodBody(source, 'Future<void> _openDownloadSettings(')),
      contains('constBrowseDownloadSettingsPage()'),
    );
  });

  test('BUG-1956：initialTab 与 initialDownloadsSection 真正决定初始页', () {
    final String source = _read(_downloadsPath);
    final String code = compactCode(source);

    // PR #1707 审查：页签控制器改由本页持有、按页签 id（不是下标）定位——
    // 初始页签从跳转请求 / initialTab 播种进 _selectedTab，控制器按它找下标。
    expect(
      code,
      contains(
        'lateBrowseTab?_selectedTab='
        'widget.navigationRequest?.tab??widget.initialTab;',
      ),
      reason: '外部入口参数不得再降级为 no-op 兼容参数',
    );
    final String sync = compactCode(
      methodBody(source, 'TabController _syncTabController('),
    );
    expect(sync, contains('tabs.indexOf(wanted)'));
    final EnclosingCall controller = enclosingCallOf(
      source,
      'initialIndex: index',
    );
    expect(controller.name, 'TabController');
    expect(compactCode(controller.text), contains('length:tabs.length'));
    expect(
      code,
      contains(
        'lateBrowseDownloadsSection_downloadsSection='
        'widget.navigationRequest?.downloadsSection??'
        'widget.initialDownloadsSection;',
      ),
      reason: '「管理订阅」等入口要能直落订阅段',
    );
    // 已挂载（首页保活）时的跳转：原地切页签与下载段，不换 key 整页重建。
    final String update = compactCode(
      methodBody(source, 'void didUpdateWidget('),
    );
    expect(update, contains('_downloadsSection=request.downloadsSection;'));
    expect(update, contains('_controllerTabs.indexOf(request.tab)'));
  });

  test('BUG-1905：返回键只看本页 ModalRoute，不被下拉框 PopupRoute 干扰', () {
    final String source = _read(_downloadsPath);
    final String header = methodBody(source, 'Widget _buildHeader(');
    final String code = maskCommentsAndScriptLines(header);

    expect(code, contains('ModalRoute.of(context)?.isFirst == false'));
    expect(code, isNot(contains('Navigator.of(context).canPop()')));
    expect(code, contains('Navigator.of(context).maybePop()'));
  });

  test('BUG-1956：资源页用单个内容域分段条复用四个模块的发现页', () {
    final String downloads = _read(_downloadsPath);
    final String code = maskCommentsAndScriptLines(downloads);
    final String downloadsStructural = maskCommentsAndStrings(downloads);

    expect(
      RegExp(
        r'_BrowseSwipeSections\s*<\s*_DownloadsResourceDomain\s*>\s*\(',
      ).allMatches(downloadsStructural),
      hasLength(1),
      reason: '资源页只能有一个外层内容域标签条（二级 tabs）',
    );
    expect(
      code,
      contains("'downloads-resource-type-picker'"),
      reason: '内容域标签条必须有稳定 key，便于焦点导航与行为验证',
    );
    expect(
      code,
      contains('enum _DownloadsResourceDomain { books, manga, games, video }'),
      reason: '类型选择必须覆盖书架、漫画、游戏、视频四个域',
    );

    expect(
      identifierCall('MediaDiscoveryPage').allMatches(downloadsStructural),
      hasLength(2),
      reason: '书架与游戏必须复用通用生产发现页',
    );
    expect(
      identifierCall('MangaDiscoveryPage').hasMatch(downloadsStructural),
      isTrue,
      reason: '漫画必须复用漫画发现页',
    );
    expect(
      identifierCall('VideoDiscoveryPage').hasMatch(downloadsStructural),
      isTrue,
      reason: '视频必须复用视频模块的生产发现页',
    );
    // 「漫画那页是**嵌入态**打开的」必须结构化判，不能钉缩进：上一版写的是
    // contains('MangaDiscoveryPage(\n          embedded: true')，加个 const 让
    // dart format 重排一次就恒假——断言的是排版不是行为。
    expect(
      RegExp(
        r'MangaDiscoveryPage\(\s*embedded:\s*true',
      ).hasMatch(downloadsStructural),
      isTrue,
      reason: '漫画发现页必须以 embedded: true 打开（否则它会自带一整套页头/导航）',
    );
    expect(code, contains('VideoDiscoveryPage('));
    expect(code, contains('embedded: true'));
    expect(code, contains('controller: widget.videoDiscoveryController'));
    expect(code, contains('actions: widget.videoDiscoveryActions'));

    expect(
      RegExp(
        r'FushiDropdown\s*<\s*_DownloadsResourceDomain\s*>\s*\(',
      ).hasMatch(downloadsStructural),
      isFalse,
      reason: '四个固定内容域应直接可见，不得退回无标签的表单型下拉框',
    );
    // 各域是可横滑的 TabBarView 页：首次到达后保活（不丢搜索词 / 结果 / 滚动），
    // 离屏页关 ticker、排除出焦点遍历。
    expect(code, contains('bool get wantKeepAlive => true;'));
    expect(identifierCall('TickerMode').hasMatch(downloadsStructural), isTrue);
    expect(
      identifierCall('ExcludeFocus').hasMatch(downloadsStructural),
      isTrue,
    );
    expect(
      downloads,
      isNot(contains('DownloadsGlobalResourceSearchSurface')),
      reason: '旧的自建全域结果面不得与模块发现页并存',
    );
  });

  test('BUG-1955：选择性下载使用当前后端落点快照', () {
    final String source = _read(_downloadActionsPath);
    final String code = maskCommentsAndScriptLines(source);

    expect(code, contains('currentVideoDownloadBackendTarget()'));
    expect(code, contains('backendTarget: target'));
    expect(
      code,
      isNot(contains('currentVideoDownloadBackendIdentity()')),
      reason: '裸后端身份已被 BUG-1879 删除，新任务必须同时快照分类',
    );
    expect(code, isNot(contains('backendIdentity: identity')));
  });
}
