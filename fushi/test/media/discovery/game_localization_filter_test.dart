import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/shinnku_discovery_source.dart';

/// BUG-1910：「gal下载缺少筛选生肉熟肉等标签」（用户 2026-08-28）。
///
/// 此前这个信息只以 `DiscoveryResourceItem.note` 里**一句硬编码中文**存在，注释自陈
/// 「原样展示，不参与任何逻辑」——既没法筛，对非中文用户还是一串看不懂的字。
/// 按显示名筛选正是本仓刚修过的反模式（BUG-1906 的导出范围按 bookTitle 字符串相等）。
///
/// 所以分类改成**带类型**的 [DiscoveryGameLocalization]，规则只有一处实现
/// （[shinnkuGameLocalization]），中文字面量的 [shinnkuGameTypeNote] 由它派生。
void main() {
  group('shinnkuGameLocalization 与 note 同源不分叉', () {
    test('路径前缀规则（与上游 get_game_type 一致）', () {
      expect(shinnkuGameLocalization('合集系列/xxx/a.7z'),
          DiscoveryGameLocalization.raw);
      expect(shinnkuGameLocalization('zd/a.7z'),
          DiscoveryGameLocalization.translated);
      expect(shinnkuGameLocalization('0/win/a.7z'),
          DiscoveryGameLocalization.translated);
      expect(shinnkuGameLocalization('0/apk/a.apk'),
          DiscoveryGameLocalization.mobile);
    });

    test('中文标注由枚举派生 —— 两种表示永远不会说不同的话', () {
      for (final String path in <String>[
        '合集系列/x/a.7z',
        'zd/a.7z',
        '0/win/a.7z',
        '0/apk/a.apk',
      ]) {
        final String expected = switch (shinnkuGameLocalization(path)) {
          DiscoveryGameLocalization.raw => '生肉',
          DiscoveryGameLocalization.translated => '熟肉',
          DiscoveryGameLocalization.mobile => '手机',
        };
        expect(shinnkuGameTypeNote(path), expected, reason: path);
      }
    });
  });

  test('shinnku 条目带上 gameLocalization（不再只靠 note 那句中文）', () {
    final String source = File(
      'lib/src/media/discovery/sources/shinnku_discovery_source.dart',
    ).readAsStringSync();
    expect(
        source.contains('gameLocalization: shinnkuGameLocalization('), isTrue,
        reason: '源必须产出带类型的分类，UI 才能按它筛选并出 i18n 标签');
  });

  test('不给分类的源保持 null —— 那是「未标注」，不是「未汉化」', () {
    const DiscoveryResourceItem item = DiscoveryResourceItem(
      sourceId: 'nyaa',
      title: 'some torrent',
      id: 'x',
      kind: DiscoveryMediaKind.game,
      payloadKind: DiscoveryPayloadKind.torrent,
      note: 'trusted',
    );
    expect(item.gameLocalization, isNull);
  });

  test('筛选是纯客户端过滤，且必须保留「未标注」档（BUG-1910）', () {
    final String page = File(
      'lib/src/pages/implementations/media_discovery_page.dart',
    ).readAsStringSync();

    // 「未标注」档：没有它，聚合搜索里一按筛选就把 sukebei / AList 整个滤没了。
    expect(page.contains('unlabelled'), isTrue,
        reason: 'sukebei / AList 的条目 gameLocalization 恒为 null，'
            '必须有一档能看见它们');
    // 目录条目不参与筛选（它们是导航结构，筛掉用户就下不去了）。
    expect(page.contains('e is! DiscoveryResourceItem ||'), isTrue,
        reason: '目录条目必须无条件保留');
    // 换筛选不得重新发起请求。
    final int start = page.indexOf('Widget? _buildHeaderLeading()');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('/// 目录下钻面包屑', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);
    expect(body.contains('setState(() => _gameTypeFilter = f)'), isTrue);
    expect(body.contains('_load('), isFalse,
        reason: '分类是条目自带的可判定属性，换筛选不该再打一次网络');
  });
}
