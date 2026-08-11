/// BUG-1566：互联通道的两个消费方只认「云备份 backendType 解析出的那一条通道」。
///
/// 根因A —— `AppModel._propagateDictionaryDeleteToRemote`：删词典只对云通道传播删除，
/// 门控还只读云备份的 `isSyncDictionaryEnabled`。用户「云备份=Google Drive + 互联启用」
/// 时对端那份删不掉，而词典是并集同步，下一轮又被拉回来 → 幽灵词典永远删不掉。
///
/// 根因B —— `showSyncCompareDialog`：只解析云通道去认证。只开互联、云后端从没配过的
/// 用户恒被告知「请先设置同步」，整个互联比较入口不可达。
///
/// 两处修法同源：通道枚举复用同步真正跑的 [enabledSyncChannelBackends]，分资产门控复用
/// [resolveChannelSyncFlags]（互联通道读互联专属开关，BUG-988 语义）。本文件既验这套
/// 同源枚举/门控在「云 + 互联」配置下的真值，也用源码扫描守卫钉住两个消费方不再退回
/// 单通道解析。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('BUG-1566 通道枚举与分通道门控（云 + 互联并存）', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = _memDb();
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('云备份=Google Drive + 互联启用 → 枚举出两条通道（云在前、互联在后）', () async {
      await repo.setBackendType(SyncBackendType.googleDrive);
      await repo.setInterconnectEnabled(true);

      final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);

      expect(channels.length, 2,
          reason: '删除传播/比较入口只看第一条 = 互联通道整条被漏掉（BUG-1566）');
      expect(channels[0].isInterconnect, isFalse);
      expect(channels[0].type, SyncBackendType.googleDrive);
      expect(channels[1].isInterconnect, isTrue);
      expect(channels[1].type, SyncBackendType.fushiServer);
      expect(channels[1].backend, isA<InterconnectSyncBackend>());
    });

    test('互联通道的词典门控读互联专属开关，不读云备份共享开关', () async {
      await repo.setBackendType(SyncBackendType.googleDrive);
      await repo.setInterconnectEnabled(true);
      // 云词典同步关、互联词典上传开——旧写法（单一 `repo.isSyncDictionaryEnabled()`
      // 一刀切）在这里会直接 return，互联对端上的词典永远删不掉。
      await repo.setSyncDictionaryEnabled(false);
      await repo.setInterconnectSyncDictionaryEnabled(true);

      final ChannelSyncFlags cloud =
          await resolveChannelSyncFlags(repo, isInterconnect: false);
      final ChannelSyncFlags interconnect =
          await resolveChannelSyncFlags(repo, isInterconnect: true);

      expect(cloud.syncDictionary, isFalse);
      expect(interconnect.syncDictionary, isTrue,
          reason: '互联通道必须读 isInterconnectSyncDictionaryEnabled（BUG-988 分通道语义）');
    });

    test('云词典开、互联词典关 → 只有云通道该被传播（反向）', () async {
      await repo.setBackendType(SyncBackendType.googleDrive);
      await repo.setInterconnectEnabled(true);
      await repo.setSyncDictionaryEnabled(true);
      await repo.setInterconnectSyncDictionaryEnabled(false);

      expect(
        (await resolveChannelSyncFlags(repo, isInterconnect: false))
            .syncDictionary,
        isTrue,
      );
      expect(
        (await resolveChannelSyncFlags(repo, isInterconnect: true))
            .syncDictionary,
        isFalse,
        reason: '互联专属开关关着时不得因为云开着就顺手动对端',
      );
    });

    test('互联未启用 → 只有云一条通道（枚举不该凭空多出互联）', () async {
      await repo.setBackendType(SyncBackendType.googleDrive);

      final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);

      expect(channels.length, 1);
      expect(channels.single.isInterconnect, isFalse);
    });
  });

  group('BUG-1566 消费方源码守卫（不得退回单通道解析）', () {
    // 断言用到的生产代码字面量（改这些名字要同步改这里）：
    //   'enabledSyncChannelBackends'  —— 同源通道枚举
    //   'resolveChannelSyncFlags'     —— 同源分通道门控
    //   'resolveSyncBackend'          —— 单通道解析，两个函数体里都不得再出现
    //   'repo.isSyncDictionaryEnabled()' —— 云备份一刀切门控，不得再出现
    test('AppModel._propagateDictionaryDeleteToRemote 遍历所有启用通道', () {
      final String body = _functionSource(
        _readSource('lib/src/models/app_model.dart'),
        '  Future<void> _propagateDictionaryDeleteToRemote(String name) async {',
        '  void clearDictionaryResultsCache()',
      );

      expect(body, contains('enabledSyncChannelBackends'),
          reason: '通道枚举必须复用同步真正跑的那一份，不得在这里重抄');
      expect(body, contains('resolveChannelSyncFlags'),
          reason: '门控必须按通道解析（互联通道读互联专属开关）');
      expect(body, isNot(contains('resolveSyncBackend')),
          reason: '单通道解析 = 互联对端的词典删不掉（BUG-1566 根因A）');
      expect(body, isNot(contains('repo.isSyncDictionaryEnabled()')),
          reason: '云备份共享开关不得再对互联通道一刀切');
    });

    test('showSyncCompareDialog 遍历所有启用通道取第一条已认证后端', () {
      final String body = _functionSource(
        _readSource('lib/src/sync/sync_compare_dialog.dart'),
        'Future<void> showSyncCompareDialog(',
        '/// 同步对比对话框：',
      );

      expect(body, contains('enabledSyncChannelBackends'),
          reason: '只开互联的用户必须能进比较对话框（BUG-1566 根因B）');
      expect(body, isNot(contains('resolveSyncBackend')),
          reason: '单通道解析 = 云后端没配过时恒报「请先设置同步」');
      expect(body, contains('sync_compare_unavailable'),
          reason: '一条通道都没认证过时仍应如实报「没配同步」，不得静默打开空对话框');
    });
  });
}

String _readSource(String relativePath) {
  final File file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: '源文件不存在：$relativePath');
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// 切出 [start] 到 [end] 之间的函数体（同 `reader_paginate_lyrics_guard_static_test`
/// 的范式）。两个标记都必须存在，否则守卫会静默扫空区间、负向断言真空通过。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: '缺起始标记：$start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: '缺结束标记：$end');
  return source.substring(startIndex, endIndex);
}
