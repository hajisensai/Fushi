import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_merge_service.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-5081：已收藏句子的改色要能跨设备 / 跨备份传播。根因：合并按内容键去重、
/// 同键保留 createdAt 更早的一条——同一条收藏两端 createdAt 相同，各留本机行，改色
/// 永远传不出去。修法：颜色带自己的 LWW 时钟（`colorUpdatedAt`，v167 列
/// `color_updated_at_us`），合并时身份仍取更早的那条、颜色取时钟较新的一侧。
final DateTime _created = DateTime.fromMicrosecondsSinceEpoch(1700000000000000);

FavoriteSentence _fav({
  required String id,
  String? color,
  DateTime? createdAt,
  DateTime? colorUpdatedAt,
}) => FavoriteSentence(
  id: id,
  text: '同じ文',
  bookTitle: 'Book',
  bookKey: 'book/a',
  sectionIndex: 3,
  normCharOffset: 42,
  normCharLength: 3,
  createdAt: createdAt ?? _created,
  color: color,
  colorUpdatedAt: colorUpdatedAt,
);

String _json(List<FavoriteSentence> l) =>
    jsonEncode(<Object?>[for (final FavoriteSentence s in l) s.toJson()]);

void main() {
  group('mergeFavoriteSentences 颜色 LWW', () {
    final FavoriteSentence untouched = _fav(id: 'hl_a', color: 'yellow');
    final FavoriteSentence recolored = _fav(
      id: 'hl_a',
      color: 'pink',
      colorUpdatedAt: _created.add(const Duration(days: 1)),
    );

    test('另一台设备改了色：两种参数顺序都取改过的颜色，结果逐字节一致', () {
      final List<FavoriteSentence> ab =
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[untouched],
            <FavoriteSentence>[recolored],
          );
      final List<FavoriteSentence> ba =
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[recolored],
            <FavoriteSentence>[untouched],
          );
      expect(ab.single.color, 'pink');
      expect(ab.single.colorUpdatedAt, recolored.colorUpdatedAt);
      expect(_json(ab), _json(ba));
      // 再合一遍不动（收敛，不会每轮都判「有变化」）。
      expect(
        _json(
          AggregateMergeService.mergeFavoriteSentences(ab, <FavoriteSentence>[
            untouched,
          ]),
        ),
        _json(ab),
      );
    });

    test('本机改色比对端新：保留本机颜色', () {
      final FavoriteSentence localNewer = _fav(
        id: 'hl_a',
        color: 'blue',
        colorUpdatedAt: _created.add(const Duration(days: 2)),
      );
      final List<FavoriteSentence> out =
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[localNewer],
            <FavoriteSentence>[recolored],
          );
      expect(out.single.color, 'blue');
    });

    test('删了重新收藏（新 createdAt 选了新色）：身份留旧行，颜色取新收藏的', () {
      final FavoriteSentence old = _fav(id: 'hl_old', color: 'yellow');
      final FavoriteSentence again = _fav(
        id: 'hl_new',
        color: 'green',
        createdAt: _created.add(const Duration(hours: 5)),
      );
      for (final List<List<FavoriteSentence>> sides
          in <List<List<FavoriteSentence>>>[
            <List<FavoriteSentence>>[
              <FavoriteSentence>[old],
              <FavoriteSentence>[again],
            ],
            <List<FavoriteSentence>>[
              <FavoriteSentence>[again],
              <FavoriteSentence>[old],
            ],
          ]) {
        final FavoriteSentence m = AggregateMergeService.mergeFavoriteSentences(
          sides[0],
          sides[1],
        ).single;
        expect(m.id, 'hl_old');
        expect(m.createdAt, _created);
        expect(m.color, 'green');
        expect(m.colorUpdatedAt, again.createdAt);
      }
    });

    test('同一微秒两端改成不同颜色：按颜色名定胜负，与参数顺序无关', () {
      final DateTime at = _created.add(const Duration(minutes: 1));
      final FavoriteSentence a = _fav(
        id: 'hl_a',
        color: 'blue',
        colorUpdatedAt: at,
      );
      final FavoriteSentence b = _fav(
        id: 'hl_a',
        color: 'purple',
        colorUpdatedAt: at,
      );
      expect(
        _json(
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[a],
            <FavoriteSentence>[b],
          ),
        ),
        _json(
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[b],
            <FavoriteSentence>[a],
          ),
        ),
      );
    });

    test('wire JSON 往返保留颜色时钟；没改过色的不写该字段（旧条目字节不变）', () {
      final FavoriteSentence back = FavoriteSentence.fromJson(
        jsonDecode(jsonEncode(recolored.toJson())) as Map<String, dynamic>,
      );
      expect(back.colorUpdatedAt, recolored.colorUpdatedAt);
      expect(untouched.toJson().containsKey('colorUpdatedAt'), isFalse);
    });

    test('颜色时钟在 wire 上是带 Z 的 UTC 绝对时刻：不同时区的设备按真实先后取色', () {
      // 本地时间的 ISO 串不带时区，别的时区读进来会差几个小时，LWW 先后判反。
      final String wire = recolored.toJson()['colorUpdatedAt']! as String;
      expect(wire, recolored.colorUpdatedAt!.toUtc().toIso8601String());
      expect(wire.endsWith('Z'), isTrue);
      // 对端（UTC+9）在本机改色之后一小时改成蓝色，wire 带显式时区偏移。
      final DateTime remoteAt = recolored.colorUpdatedAt!.add(
        const Duration(hours: 1),
      );
      final Map<String, dynamic> remoteJson =
          jsonDecode(jsonEncode(recolored.toJson())) as Map<String, dynamic>
            ..['color'] = 'blue'
            ..['colorUpdatedAt'] = remoteAt
                .toUtc()
                .add(const Duration(hours: 9))
                .toIso8601String()
                .replaceFirst('Z', '+09:00');
      final FavoriteSentence remote = FavoriteSentence.fromJson(remoteJson);
      expect(
        remote.colorUpdatedAt!.microsecondsSinceEpoch,
        remoteAt.microsecondsSinceEpoch,
      );
      final FavoriteSentence m = AggregateMergeService.mergeFavoriteSentences(
        <FavoriteSentence>[recolored],
        <FavoriteSentence>[remote],
      ).single;
      expect(m.color, 'blue');
      expect(m.toJson()['colorUpdatedAt'], remoteAt.toUtc().toIso8601String());
    });
  });

  test('FavoriteSentenceRepository.setColor 落库颜色与时钟，getAll 读回', () async {
    final Directory dir = await Directory.systemTemp.createTemp('fs_recolor_');
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    await repo.add(_fav(id: 'hl_a', color: 'yellow'));
    final DateTime at = _created.add(const Duration(days: 3));

    expect(await repo.setColor('hl_a', 'purple', at: at), isTrue);
    expect(await repo.setColor('missing', 'purple', at: at), isFalse);

    final FavoriteSentence row = (await repo.getAll()).single;
    expect(row.color, 'purple');
    expect(row.colorUpdatedAt, at);
    expect(row.createdAt, _created, reason: '改色不动收藏时刻（内容身份）');
  });

  for (final bool backupNewer in <bool>[true, false]) {
    test('备份合并导入：颜色取时钟较新的一侧（${backupNewer ? '备份' : '本机'}更新）', () async {
      final DateTime older = _created.add(const Duration(days: 1));
      final DateTime newer = _created.add(const Duration(days: 2));

      final Directory curDir = await Directory.systemTemp.createTemp('fs_cur_');
      addTearDown(() => cleanupTempDir(curDir));
      final FushiDatabase cur = FushiDatabase(curDir.path);
      final FavoriteSentenceRepository curRepo = FavoriteSentenceRepository(
        cur,
      );
      await curRepo.add(_fav(id: 'hl_cur', color: 'yellow'));
      await curRepo.setColor('hl_cur', 'blue', at: backupNewer ? older : newer);
      await cur.close();

      final Directory srcDir = await Directory.systemTemp.createTemp('fs_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final FushiDatabase src = FushiDatabase(srcDir.path);
      final FavoriteSentenceRepository srcRepo = FavoriteSentenceRepository(
        src,
      );
      await srcRepo.add(_fav(id: 'hl_src', color: 'yellow'));
      await srcRepo.setColor('hl_src', 'pink', at: backupNewer ? newer : older);
      final Directory zipDir = await Directory.systemTemp.createTemp('fs_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final String zip = p.join(zipDir.path, 'b.zip');
      await BackupService(
        db: src,
        dbDirectory: srcDir.path,
        appVersion: '2.0.0',
      ).createBackup(zip);
      await src.close();

      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path,
        zipPath: zip,
      );

      final FushiDatabase after = FushiDatabase(curDir.path);
      addTearDown(after.close);
      final FavoriteSentence merged = (await FavoriteSentenceRepository(
        after,
      ).getAll()).single;
      expect(merged.color, backupNewer ? 'pink' : 'blue');
      expect(merged.colorUpdatedAt, newer);
    });
  }
}
