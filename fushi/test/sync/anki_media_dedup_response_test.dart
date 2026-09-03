/// BUG-1682：互联媒体存储优化的主机端端点契约。
///
/// 客户端（手机）经互联对**主机端** collection.media 去重。这里守两条要害：
///   1. `dryRun` 缺省必须是 **true**——真删的决定权在客户端用户手里，缺字段的
///      旧客户端或坏请求绝不能被解读成「删吧」；
///   2. 主机后端不支持时 `report` 为 null，不能编造一个「没有重复」的空报告。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _FakeMining implements FushiRemoteMiningService {
  bool available = true;
  AnkiMediaDedupReport? report;
  final List<bool> runs = <bool>[];

  @override
  Future<bool> probeMediaMaintenance() async => available;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async {
    runs.add(dryRun);
    return report;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} must not run');
}

const AnkiMediaDedupReport _plan = AnkiMediaDedupReport(
  dryRun: true,
  groupCount: 1,
  deletions: <MediaDedupDeletion>[
    MediaDedupDeletion(filename: 'dupe.jpg', canonical: 'keep.jpg', bytes: 42),
  ],
  notesRewritten: 3,
  modelsRewritten: 1,
  skipped: 2,
);

void main() {
  group('POST /api/anki/media/dedup/probe', () {
    test('把主机端探测结论原样报回', () async {
      final _FakeMining mining = _FakeMining()..available = true;
      expect(
        await buildAnkiMediaDedupProbeResponse(mining: mining),
        <String, dynamic>{'available': true},
      );

      mining.available = false;
      expect(
        await buildAnkiMediaDedupProbeResponse(mining: mining),
        <String, dynamic>{'available': false},
      );
    });
  });

  group('POST /api/anki/media/dedup/run', () {
    test('缺 dryRun 字段 → 干跑（安全默认，一个文件都不动）', () async {
      final _FakeMining mining = _FakeMining()..report = _plan;
      await buildAnkiMediaDedupRunResponse(
        <String, dynamic>{},
        mining: mining,
      );
      expect(mining.runs, <bool>[true]);
    });

    test('dryRun=false 才真跑', () async {
      final _FakeMining mining = _FakeMining()..report = _plan;
      await buildAnkiMediaDedupRunResponse(
        <String, dynamic>{'dryRun': false},
        mining: mining,
      );
      expect(mining.runs, <bool>[false]);
    });

    test('dryRun 类型错 → FormatException（调用方转 400），绝不当成 false', () async {
      final _FakeMining mining = _FakeMining()..report = _plan;
      await expectLater(
        buildAnkiMediaDedupRunResponse(
          <String, dynamic>{'dryRun': 'false'},
          mining: mining,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(mining.runs, isEmpty);
    });

    test('报告可完整序列化并还原（客户端要拿它画删除清单）', () async {
      final _FakeMining mining = _FakeMining()..report = _plan;
      final Map<String, dynamic> body = await buildAnkiMediaDedupRunResponse(
        <String, dynamic>{'dryRun': true},
        mining: mining,
      );
      final AnkiMediaDedupReport back = AnkiMediaDedupReport.fromJson(
        Map<String, dynamic>.from(body['report'] as Map),
      );
      expect(back.dryRun, isTrue);
      expect(back.groupCount, 1);
      expect(back.notesRewritten, 3);
      expect(back.modelsRewritten, 1);
      expect(back.skipped, 2);
      expect(back.cancelled, isFalse);
      expect(back.deletions.single.filename, 'dupe.jpg');
      expect(back.deletions.single.canonical, 'keep.jpg');
      // 派生值从 deletions 重算，不从 wire 上读——两份数字迟早对不上。
      expect(back.duplicatesRemoved, 1);
      expect(back.bytesSaved, 42);
    });

    test('主机后端不支持 → report 为 null，不编造空报告', () async {
      final _FakeMining mining = _FakeMining()..report = null;
      final Map<String, dynamic> body = await buildAnkiMediaDedupRunResponse(
        <String, dynamic>{'dryRun': true},
        mining: mining,
      );
      expect(body['report'], isNull);
    });
  });
}
