import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String _downloadsPath =
    'lib/src/pages/implementations/downloads_page.dart';
const String _downloadActionsPath =
    'lib/src/pages/implementations/download_actions.dart';

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: '守卫语料文件不存在：$path');
  return file.readAsStringSync();
}

void main() {
  test('BUG-1956：下载中心保留资源、任务、订阅、设置四个顶层页签', () {
    final String source = _read(_downloadsPath);
    final String code = maskCommentsAndScriptLines(source);
    final String structural = maskCommentsAndStrings(source);

    expect(
      RegExp(r'\bLibrarySectionTab<int>\s*\(').allMatches(code),
      hasLength(4),
      reason: '下载中心顶层只能有且必须有四个目的地',
    );
    final List<String> labels = <String>[
      'label: t.download_resources_tab',
      'label: t.download_tasks_tab',
      'label: t.download_subscriptions_tab',
      'label: t.settings',
    ];
    int previous = -1;
    for (final String label in labels) {
      final int current = code.indexOf(label);
      expect(current, greaterThan(previous), reason: '页签缺失或顺序错误：$label');
      previous = current;
    }

    expect(identifierCall('DefaultTabController').hasMatch(structural), isTrue);
    expect(identifierCall('TabBarView').hasMatch(structural), isTrue);
    expect(
      identifierCall('VideoDownloadJobsPanel').hasMatch(structural),
      isTrue,
      reason: '任务页不得再被从下载中心拆掉',
    );
    expect(
      identifierCall('VideoDownloadSubscriptionsPanel').hasMatch(structural),
      isTrue,
      reason: '订阅页不得再被从下载中心拆掉',
    );
    expect(
      identifierCall('TorrentSettingsSection').hasMatch(structural),
      isTrue,
      reason: '设置页不得再被从下载中心拆掉',
    );
  });

  test('BUG-1956：initialTabIndex 与 initialShowSettings 真正决定初始页', () {
    final String source = _read(_downloadsPath);
    final EnclosingCall controller = enclosingCallOf(
      source,
      'widget.initialShowSettings',
    );
    expect(controller.name, 'DefaultTabController');
    final String code = compactCode(controller.text);

    expect(code, contains('length:4'));
    expect(
      code,
      contains(
        'initialIndex:widget.initialShowSettings?3:'
        'widget.initialTabIndex.clamp(0,2)',
      ),
      reason: '这两个外部入口参数不得再降级为 no-op 兼容参数',
    );
  });

  test('BUG-1905：返回键只看本页 ModalRoute，不被下拉框 PopupRoute 干扰', () {
    final String source = _read(_downloadsPath);
    final String header = methodBody(source, 'Widget _buildHeader(');
    final String code = maskCommentsAndScriptLines(header);

    expect(code, contains('ModalRoute.of(context)?.isFirst == false'));
    expect(code, isNot(contains('Navigator.of(context).canPop()')));
    expect(code, contains('Navigator.of(context).maybePop()'));
  });

  test('BUG-1956：资源页用单个类型下拉框复用四个模块的发现页', () {
    final String downloads = _read(_downloadsPath);
    final String code = maskCommentsAndScriptLines(downloads);
    final String downloadsStructural = maskCommentsAndStrings(downloads);

    expect(
      RegExp(
        r'FushiDropdown\s*<\s*_DownloadsResourceDomain\s*>\s*\(',
      ).allMatches(downloadsStructural),
      hasLength(1),
      reason: '资源页只能有一个外层内容类型下拉框',
    );
    expect(
      code,
      contains("'downloads-resource-type-picker'"),
      reason: '类型下拉框必须有稳定 key，便于焦点导航与行为验证',
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
      RegExp(r'MangaDiscoveryPage\(\s*embedded:\s*true')
          .hasMatch(downloadsStructural),
      isTrue,
      reason: '漫画发现页必须以 embedded: true 打开（否则它会自带一整套页头/导航）',
    );
    expect(code, contains('VideoDiscoveryPage('));
    expect(code, contains('embedded: true'));
    expect(code, contains('controller: widget.videoDiscoveryController'));
    expect(code, contains('actions: widget.videoDiscoveryActions'));

    expect(
      identifierCall('FushiSegmentedStrip').hasMatch(downloadsStructural),
      isFalse,
      reason: '外层类型选择按用户裁定使用下拉框，不再铺成分段筛选条',
    );
    expect(code, contains('_visitedResourceDomains'));
    expect(identifierCall('Offstage').hasMatch(downloadsStructural), isTrue);
    expect(identifierCall('TickerMode').hasMatch(downloadsStructural), isTrue);
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
    expect(code, isNot(contains('currentVideoDownloadBackendIdentity()')),
        reason: '裸后端身份已被 BUG-1879 删除，新任务必须同时快照分类');
    expect(code, isNot(contains('backendIdentity: identity')));
  });
}
