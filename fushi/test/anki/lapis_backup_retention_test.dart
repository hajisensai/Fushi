// PR#457 审查 §10-5a（用户拍板方案乙）守卫：Lapis 备份保留 90 天，**但无论
// 如何最少留最近 10 份**。删除不可逆，边界必须钉死：正好 10 份不删、正好 90 天
// 不删、时刻解析不出不删。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/lapis_backup_retention.dart';
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _TempDirLapisService extends LapisTemplateService {
  _TempDirLapisService(super.repository, this._dir);

  final Directory _dir;

  @override
  Future<Directory> backupDirectory() async => _dir;
}

class _FakeRepo extends BaseAnkiRepository {
  AnkiSettings settings = const AnkiSettings();

  @override
  bool get supportsNoteTypeEditing => true;

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => settings = s;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
          String modelName) async =>
      AnkiNoteTypeDefinition(
        name: LapisNoteType.modelName,
        fields: LapisNoteType.fields,
        templates: const <AnkiCardTemplate>[],
        css: LapisNoteType.template.css,
      );

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

/// 测试用的备份条目：文件名 + 期望时刻（时刻由文件名解析，两者必须自洽）。
String _backupName(DateTime at) =>
    'lapis-${at.toUtc().toIso8601String().replaceAll(':', '-')}.json';

List<String> _namesNewestFirst(List<DateTime> newestFirst) =>
    newestFirst.map(_backupName).toList(growable: false);

List<String> _prune(List<String> names, DateTime now) =>
    planLapisBackupPrune<String>(
      names,
      timestampOf: parseLapisBackupTimestamp,
      now: now,
    );

void main() {
  final DateTime now = DateTime.utc(2026, 7, 27, 12);

  test('文件名 ↔ 时刻往返（保留策略与界面标签用的是同一份判据）', () {
    final DateTime at = DateTime.utc(2026, 3, 4, 5, 6, 7, 890);
    expect(parseLapisBackupTimestamp(_backupName(at)), at);
    expect(parseLapisBackupTimestamp('lapis-garbage.json'), isNull);
    expect(parseLapisBackupTimestamp('other-file.json'), isNull);
    expect(parseLapisBackupTimestamp('lapis-2026-01-01T00-00-00.000Z.txt'),
        isNull);
  });

  test('边界：正好 10 份、全都远超 90 天 → 一份都不删', () {
    final List<String> names = _namesNewestFirst(<DateTime>[
      for (int i = 0; i < 10; i++) now.subtract(Duration(days: 300 + i)),
    ]);
    expect(_prune(names, now), isEmpty);
  });

  test('边界：第 11 份正好 90 天 → 不删（严格大于才算过期）', () {
    final List<String> names = _namesNewestFirst(<DateTime>[
      for (int i = 0; i < 10; i++) now.subtract(Duration(days: i)),
      now.subtract(const Duration(days: 90)),
    ]);
    expect(names, hasLength(11));
    expect(_prune(names, now), isEmpty);
  });

  test('边界：第 11 份 90 天零 1 毫秒 → 删这一份', () {
    final DateTime doomedAt =
        now.subtract(const Duration(days: 90, milliseconds: 1));
    final List<String> names = _namesNewestFirst(<DateTime>[
      for (int i = 0; i < 10; i++) now.subtract(Duration(days: i)),
      doomedAt,
    ]);
    expect(_prune(names, now), <String>[_backupName(doomedAt)]);
  });

  test('两个条件同时成立才删：排 11 位之后 + 超 90 天', () {
    final List<DateTime> stamps = <DateTime>[
      // 最近 12 份都很新（其中 11、12 位不满 90 天）。
      for (int i = 0; i < 12; i++) now.subtract(Duration(days: i)),
      // 13、14 位超 90 天 → 该删。
      now.subtract(const Duration(days: 100)),
      now.subtract(const Duration(days: 400)),
    ];
    final List<String> names = _namesNewestFirst(stamps);
    expect(
      _prune(names, now),
      <String>[_backupName(stamps[12]), _backupName(stamps[13])],
    );
  });

  test('时刻解析不出的条目永不删（年龄不可判定 → 保守保留）', () {
    final List<String> names = <String>[
      for (int i = 0; i < 10; i++) _backupName(now.subtract(Duration(days: i))),
      'lapis-not-a-timestamp.json',
      _backupName(now.subtract(const Duration(days: 999))),
    ];
    expect(
      _prune(names, now),
      <String>[_backupName(now.subtract(const Duration(days: 999)))],
    );
  });

  test('少于保留下限时直接短路（一份都不碰）', () {
    expect(_prune(<String>[], now), isEmpty);
    expect(
      _prune(
        _namesNewestFirst(<DateTime>[now.subtract(const Duration(days: 9999))]),
        now,
      ),
      isEmpty,
    );
  });

  test('默认策略常量就是用户拍板的 90 天 / 最少 10 份', () {
    expect(kLapisBackupMaxAge, const Duration(days: 90));
    expect(kLapisBackupKeepMinimum, 10);
  });

  group('落盘层：清理只在用户主动备份写盘之后发生，且结果可见', () {
    late Directory dir;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      dir = await Directory.systemTemp.createTemp('lapis_prune_io_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> seed(List<DateTime> stamps) async {
      for (final DateTime at in stamps) {
        await File('${dir.path}${Platform.pathSeparator}${_backupName(at)}')
            .writeAsString('{}');
      }
    }

    test('手动备份：过期且排在 10 份之外的被删，份数回给 UI', () async {
      final DateTime now = DateTime.now().toUtc();
      await seed(<DateTime>[
        // 10 份新的（都不满 90 天）+ 2 份远超 90 天的。
        for (int i = 1; i <= 10; i++) now.subtract(Duration(days: i)),
        now.subtract(const Duration(days: 300)),
        now.subtract(const Duration(days: 400)),
      ]);

      final LapisBackupOutcome? outcome =
          await _TempDirLapisService(_FakeRepo(), dir).backupNow();

      expect(outcome, isNotNull);
      expect(await outcome!.file.exists(), isTrue);
      // 新备份挤进第 1 位 → 最近 10 份 = 新备份 + 9 份新的；第 11 位那份虽然
      // 掉出了保留窗口但只有 10 天大，不满 90 天照样留着；只有最后两份同时
      // 满足「窗口外 + 超 90 天」，删的就是它们。
      expect(outcome.prunedCount, 2);
      final List<File> left =
          await _TempDirLapisService(_FakeRepo(), dir).listBackups();
      expect(left, hasLength(11));
    });

    test('不足 10 份时一份都不删，哪怕全都远超 90 天', () async {
      final DateTime now = DateTime.now().toUtc();
      await seed(<DateTime>[
        for (int i = 0; i < 5; i++) now.subtract(Duration(days: 900 + i)),
      ]);

      final LapisBackupOutcome? outcome =
          await _TempDirLapisService(_FakeRepo(), dir).backupNow();

      expect(outcome!.prunedCount, 0);
      expect(
        await _TempDirLapisService(_FakeRepo(), dir).listBackups(),
        hasLength(6),
      );
    });
  });
}
