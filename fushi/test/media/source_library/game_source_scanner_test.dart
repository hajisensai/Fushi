// 反馈 9Rm_8JEkGM：游戏库支持「添加来源」扫描目录（SourceLibraryKind.game）。
//
// 钉住：游戏目录识别（第一层直接含 exe 的目录一条、不往游戏子树里找、根自己含 exe
// 时整根一条、「含子文件夹」关闭只看两层）、主 exe 选择、增量（重扫不重复添加、
// 不改回用户改过的 exe、认领手动添加过的游戏、被删的游戏重扫再登记）、来源计数、
// SourceLibraryScanner 的 game 分派与装配钩子、网络来源拒收、移除来源保留游戏只清索引。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/game_source_scanner.dart';
import 'package:fushi/src/media/source_library/source_library_removal.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late FushiDatabase db;

  /// 在临时根下放一个文件（目录自动建），返回绝对路径。
  String touch(String rel, {int bytes = 1}) {
    final File f = File(p.joinAll(<String>[tmp.path, ...rel.split('/')]));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 0));
    return f.path;
  }

  Future<int> insertGameSource({String transport = 'local'}) =>
      db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'games',
          mediaKind: SourceLibraryKind.game.dbValue,
          rootPath: tmp.path,
          transport: Value<String>(transport),
          createdAt: 1,
        ),
      );

  Future<Map<String, GalgameRow>> gamesByName() async => <String, GalgameRow>{
    for (final GalgameRow r in await db.getAllGalgames()) r.name: r,
  };

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_game_source_');
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (dynamic raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });

  tearDown(() async {
    onGameSourceScanned = null;
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('findGameDirectories', () {
    test('第一层直接含 exe 的目录各一条，不进游戏子树，无 exe 的目录不算', () async {
      touch('ATRI/atri.exe');
      touch('ATRI/tools/config.exe');
      touch('Brand/GameB/game.exe');
      touch('Brand/GameB/data/patch/updater.exe');
      touch('Docs/readme.txt');

      final List<GameDirectoryCandidate> dirs = await findGameDirectories(
        tmp.path,
      );

      expect(
        dirs.map((GameDirectoryCandidate d) => d.directoryPath).toList(),
        <String>[p.join(tmp.path, 'ATRI'), p.join(tmp.path, 'Brand', 'GameB')],
      );
      expect(
        dirs.first.exePaths.keys,
        <String>[p.join(tmp.path, 'ATRI', 'atri.exe')],
        reason: '游戏自带 tools/ 里的 exe 属于这个游戏，不另成一条',
      );
    });

    test('「含子文件夹」关闭：只看根与根的直接子目录', () async {
      touch('ATRI/atri.exe');
      touch('Brand/GameB/game.exe');

      final List<GameDirectoryCandidate> dirs = await findGameDirectories(
        tmp.path,
        recursive: false,
      );

      expect(
        dirs.map((GameDirectoryCandidate d) => d.directoryPath).toList(),
        <String>[p.join(tmp.path, 'ATRI')],
      );
    });

    test('来源根自己直接含 exe：整个根是一个游戏', () async {
      touch('game.exe');
      touch('sub/other.exe');

      final List<GameDirectoryCandidate> dirs = await findGameDirectories(
        tmp.path,
      );

      expect(dirs, hasLength(1));
      expect(p.equals(dirs.single.directoryPath, tmp.path), isTrue);
    });

    test('扩展名大小写无关（与「添加游戏」同一判据）', () async {
      touch('Old/GAME.EXE');
      final List<GameDirectoryCandidate> dirs = await findGameDirectories(
        tmp.path,
      );
      expect(dirs.single.exePaths.keys.single, endsWith('GAME.EXE'));
      expect(isGameExePath('x.Exe'), isTrue);
      expect(isGameExePath('x.exe.txt'), isFalse);
      expect(isGameExePath(''), isFalse);
    });

    test('来源根不存在：抛 FileSystemException（整次扫描读不了）', () async {
      await expectLater(
        findGameDirectories(p.join(tmp.path, 'missing')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('pickGameDirectoryExe', () {
    test('与目录名同名的 exe 优先', () {
      expect(
        pickGameDirectoryExe('ATRI', <String, int?>{
          r'D:\G\ATRI\launcher.exe': 9000,
          r'D:\G\ATRI\atri.exe': 10,
        }),
        r'D:\G\ATRI\atri.exe',
      );
    });

    test('辅助程序（卸载 / 设置 / 崩溃上报）降权，其余按大小', () {
      expect(
        pickGameDirectoryExe('SomeGame', <String, int?>{
          r'D:\G\SomeGame\unins000.exe': 5000000,
          r'D:\G\SomeGame\UnityCrashHandler64.exe': 1200000,
          r'D:\G\SomeGame\config.exe': 900000,
          r'D:\G\SomeGame\main.exe': 650000,
          r'D:\G\SomeGame\small.exe': 1000,
        }),
        r'D:\G\SomeGame\main.exe',
      );
    });

    test('只有辅助程序时照样选它（只降权不排除）；空表返回 null', () {
      expect(
        pickGameDirectoryExe('X', <String, int?>{r'D:\X\setup.exe': 1}),
        r'D:\X\setup.exe',
      );
      expect(pickGameDirectoryExe('X', const <String, int?>{}), isNull);
    });

    test('isAuxiliaryGameExeName', () {
      expect(isAuxiliaryGameExeName('unins000'), isTrue);
      expect(isAuxiliaryGameExeName('Uninstall'), isTrue);
      expect(isAuxiliaryGameExeName('vc_redist.x64'), isTrue);
      expect(isAuxiliaryGameExeName('atri'), isFalse);
      expect(isAuxiliaryGameExeName('launcher'), isFalse);
    });
  });

  group('scanGameSource', () {
    test('新目录各建一条：名称取目录名，exe 选主程序，工作目录是 exe 所在目录', () async {
      final String atri = touch('ATRI/atri.exe', bytes: 10);
      touch('ATRI/unins000.exe', bytes: 5000);
      touch('Brand/GameB/game.exe');
      final int sourceId = await insertGameSource();

      final GameSourceScanResult result = await scanGameSource(
        db: db,
        sourceId: sourceId,
        rootPath: tmp.path,
        now: DateTime.fromMicrosecondsSinceEpoch(1000),
      );

      expect(result.createdGameIds, hasLength(2));
      expect(result.adoptedGameIds, isEmpty);
      final Map<String, GalgameRow> games = await gamesByName();
      expect(games.keys.toSet(), <String>{'ATRI', 'GameB'});
      expect(games['ATRI']!.exePath, atri);
      expect(games['ATRI']!.workdir, p.join(tmp.path, 'ATRI'));
      expect(await countGamesOfSource(db, sourceId), 2);
    });

    test('重扫增量：不重复添加，也不改回用户改过的 exe / 名称', () async {
      touch('ATRI/atri.exe');
      final String alt = touch('ATRI/atri_dx.exe');
      final int sourceId = await insertGameSource();
      await scanGameSource(db: db, sourceId: sourceId, rootPath: tmp.path);
      final GalgameRow first = (await db.getAllGalgames()).single;
      // 用户在详情页改了启动 exe 与名称。
      await db.upsertGalgame(
        first
            .toCompanion(true)
            .copyWith(exePath: Value<String>(alt), name: const Value('Mine')),
      );
      touch('NewGame/new.exe');

      final GameSourceScanResult again = await scanGameSource(
        db: db,
        sourceId: sourceId,
        rootPath: tmp.path,
      );

      expect(again.createdGameIds, hasLength(1), reason: '只有新目录 NewGame');
      final Map<String, GalgameRow> games = await gamesByName();
      expect(games.keys.toSet(), <String>{'Mine', 'NewGame'});
      expect(games['Mine']!.exePath, alt);
      expect(await countGamesOfSource(db, sourceId), 2);
    });

    test('库里已有 exe 落在该目录的游戏（手动添加过）：认领、不重复添加', () async {
      final String exe = touch('ATRI/atri.exe');
      final GalgameEntry manual = newGalgameEntryFromExe(
        exe,
        now: DateTime.fromMicrosecondsSinceEpoch(42),
      );
      await db.upsertGalgame(galgamesCompanionFromEntry(manual));
      final int sourceId = await insertGameSource();

      final GameSourceScanResult result = await scanGameSource(
        db: db,
        sourceId: sourceId,
        rootPath: tmp.path,
      );

      expect(result.createdGameIds, isEmpty);
      expect(result.adoptedGameIds, <String>[manual.id]);
      expect(await db.getAllGalgames(), hasLength(1));
      expect(await countGamesOfSource(db, sourceId), 1);
    });

    test('用户从库里删掉的游戏：认领作废，重扫再登记（与书来源同语义）', () async {
      touch('ATRI/atri.exe');
      final int sourceId = await insertGameSource();
      await scanGameSource(db: db, sourceId: sourceId, rootPath: tmp.path);
      await db.deleteGalgame((await db.getAllGalgames()).single.id);
      expect(await countGamesOfSource(db, sourceId), 0);

      final GameSourceScanResult again = await scanGameSource(
        db: db,
        sourceId: sourceId,
        rootPath: tmp.path,
      );

      expect(again.createdGameIds, hasLength(1));
      expect(await countGamesOfSource(db, sourceId), 1);
    });

    test('新 id 撞上库里已有 id 时顺延，不覆盖已有游戏', () async {
      final GalgameEntry other = newGalgameEntryFromExe(
        r'E:\Elsewhere\other.exe',
        now: DateTime.fromMicrosecondsSinceEpoch(1000),
      );
      await db.upsertGalgame(galgamesCompanionFromEntry(other));
      touch('ATRI/atri.exe');
      final int sourceId = await insertGameSource();

      final GameSourceScanResult result = await scanGameSource(
        db: db,
        sourceId: sourceId,
        rootPath: tmp.path,
        now: DateTime.fromMicrosecondsSinceEpoch(1000),
      );

      expect(result.createdGameIds.single, isNot(other.id));
      final Map<String, GalgameRow> games = await gamesByName();
      expect(games['other']!.exePath, r'E:\Elsewhere\other.exe');
      expect(games.keys.toSet(), <String>{'other', 'ATRI'});
    });

    test('目录被删：游戏留在库里（app 内扫描不回收，与书 / 视频来源同口径）', () async {
      touch('ATRI/atri.exe');
      final int sourceId = await insertGameSource();
      await scanGameSource(db: db, sourceId: sourceId, rootPath: tmp.path);
      Directory(p.join(tmp.path, 'ATRI')).deleteSync(recursive: true);

      await scanGameSource(db: db, sourceId: sourceId, rootPath: tmp.path);

      expect(await db.getAllGalgames(), hasLength(1));
    });
  });

  group('SourceLibraryScanner 的 game 分派', () {
    test('本地游戏来源：写回来源行、摘要计新增、装配钩子收到新建 id', () async {
      touch('ATRI/atri.exe');
      touch('GameB/game.exe');
      final int sourceId = await insertGameSource();
      List<String>? hooked;
      onGameSourceScanned = (List<String> created) => hooked = created;

      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
      ).scan((await db.getMediaSourceById(sourceId))!);

      expect(summary.error, isNull);
      expect(summary.importedMediaCount, 2);
      expect(summary.discoveredPaths, hasLength(2));
      expect(hooked, hasLength(2));
      final MediaSourceRow row = (await db.getMediaSourceById(sourceId))!;
      expect(row.mediaCount, 2);
      expect(row.lastScanError, isNull);
      expect(await db.getAllGalgames(), hasLength(2));

      // 重扫：没有新增，钩子仍被调（游戏库缓存要重载），计数为本轮新增 0。
      final SourceScanSummary again = await SourceLibraryScanner(
        db,
      ).scan((await db.getMediaSourceById(sourceId))!);
      expect(again.importedMediaCount, 0);
      expect(hooked, isEmpty);
      expect(await db.getAllGalgames(), hasLength(2));
    });

    test('网络游戏来源：如实报错，不建任何游戏', () async {
      touch('ATRI/atri.exe');
      final int sourceId = await insertGameSource(transport: 'sftp');

      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
      ).scan((await db.getMediaSourceById(sourceId))!);

      expect(summary.error, contains('local folders only'));
      expect(await db.getAllGalgames(), isEmpty);
      expect(
        (await db.getMediaSourceById(sourceId))!.lastScanError,
        contains('local folders only'),
      );
    });

    test('来源根不存在：错误记进来源行', () async {
      final int sourceId = await insertGameSource();
      tmp.deleteSync(recursive: true);

      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
      ).scan((await db.getMediaSourceById(sourceId))!);

      expect(summary.error, isNotNull);
      expect((await db.getMediaSourceById(sourceId))!.lastScanError, isNotNull);
    });
  });

  test('移除游戏来源：游戏留在库里，只清来源扫描索引', () async {
    touch('ATRI/atri.exe');
    final int sourceId = await insertGameSource();
    await scanGameSource(db: db, sourceId: sourceId, rootPath: tmp.path);
    expect(await db.getPref(bookSourceScanIndexPrefKey(sourceId)), isNotNull);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    await removeSourceLibrary(
      database: db,
      prefs: prefs,
      sourceId: sourceId,
    );

    expect(await db.getMediaSourceById(sourceId), isNull);
    expect(await db.getAllGalgames(), hasLength(1));
    expect(await db.getPref(bookSourceScanIndexPrefKey(sourceId)), isNull);
  });
}
