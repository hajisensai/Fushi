import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR#914 阻塞②：per-book 统计（`statistics_*.json`）的两条调用点必须与全量 sweep
/// 一样分通道。
///
/// 统计有两条互相独立的通道：聚合快照（sweep，PR#914 已裁）+ per-book
/// `statistics_*.json`（PR#914 没管）。互联后端**真的实现了**后者
/// （`InterconnectSyncBackend.updateStatsFile` / `findSyncFileByPrefix(files,
/// 'statistics_')`），所以「关掉共享统计后 sweep 停了，可每次退出一本书仍把该书统计
/// PUT 给互联 host 再 merge 回本地」是真实可达的失败路径，且与 sweep 互相打架
/// （同一份 per-book 统计，sweep 听互联键、退出书听云键）。
///
/// 修法与 BUG-1566 的 `interconnect_channel_consumers_test` 同源：消费方一律走
/// [resolveChannelSyncFlags]，不再各自读单个 `repo.isXxxEnabled()`。本文件用源码扫描
/// 钉住两个调用点。
///
/// 断言用到的生产代码字面量（改名要同步改这里）：
///   'resolveChannelSyncFlags'      —— 同源分通道门控
///   'flags.syncStats'              —— per-book 统计必须取自分通道解析结果
///   'repo.isSyncStatsEnabled()'    —— 云备份一刀切读法，两处都不得再出现
///   'isInterconnectSyncStatsEnabled' —— 也不得在消费方重抄分通道三元式
void main() {
  group('PR#914 ② per-book 统计分通道（源码守卫）', () {
    test('退出书同步（_runAutoSync）按通道解析统计开关', () {
      final String body = _functionSource(
        _readSource('lib/src/sync/sync_auto_trigger.dart'),
        'Future<void> _runAutoSync({',
        "    'Auto-sync failed for \$mediaIdentifier',",
      );

      expect(body, contains('resolveChannelSyncFlags('),
          reason: '门控必须复用同一份分通道解析，不得在这里重抄');
      expect(body, contains('syncStats: flags.syncStats'),
          reason: 'per-book 统计必须取自分通道解析结果');
      expect(body, isNot(contains('repo.isSyncStatsEnabled()')),
          reason: '云备份共享开关不得对互联通道的 per-book 统计一刀切（PR#914 ②）');
      expect(body, isNot(contains('isInterconnectSyncStatsEnabled')),
          reason: '别在消费方重抄三元式——那正是当年 content 分了、stats 忘了的形状');
    });

    test('手动「解决冲突并应用」（_applyChoices）按通道解析统计开关', () {
      final String body = _functionSource(
        _readSource('lib/src/sync/sync_compare_dialog.dart'),
        '  Future<void> _applyChoices() async {',
        '  /// 750a：互联下载远端独有书时补下其有声书包（若有）。',
      );

      expect(body, contains('resolveChannelSyncFlags('),
          reason: '手动应用与自动同步必须同一份门控');
      expect(body, contains('flags.syncStats'),
          reason: 'per-book 统计必须取自分通道解析结果');
      expect(body, isNot(contains('repo.isSyncStatsEnabled()')),
          reason: '关掉互联「共享统计」后，手动应用一本书也不得再推该书统计（PR#914 ②）');
      expect(body, isNot(contains('isInterconnectSyncContentEnabled')),
          reason: '内容也一并归 resolveChannelSyncFlags，不留手抄三元式');
    });

    test('互联后端确有 per-book 统计通道（否则本守卫在守一个不存在的路径）', () {
      final String backend =
          _readSource('lib/src/sync/interconnect_sync_backend.dart');
      expect(backend, contains('updateStatsFile'));
      expect(backend, contains("'statistics_'"));
    });
  });
}

String _readSource(String relativePath) {
  final File file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: '源文件不存在：$relativePath');
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// 切出 [start] 到 [end] 之间的函数体。两个标记都必须存在，否则守卫会静默扫空区间、
/// 让负向断言真空通过（与 `interconnect_channel_consumers_test` 同一范式）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: '缺起始标记：$start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: '缺结束标记：$end');
  return source.substring(startIndex, endIndex);
}
