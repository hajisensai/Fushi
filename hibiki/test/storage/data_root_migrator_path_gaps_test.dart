import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/path_rebase_coverage.dart';

/// BUG-1174：数据根迁移的**路径改写**四处存量缺陷的行为守卫。
///
///  ① 漏改的列 / pref：galgames.cover_path、video_books.subtitle_source ×2、
///     media_items.image_url、profile_settings.value、galgame_library /
///     video_remote_subtitle / download_save_root(+history) / local_audio_db_path。
///  ② profile_settings 快照会把刚 rebase 好的路径整体退回旧值（切一次 Profile 就中招）。
///  ③ 新根落在旧根内部时，`startsWith(oldRoot)` 判据会把路径改写两遍 → 静默毁库。
///  ④ 改写必须在单事务里，中途失败整体回滚。
class _FakeAnkiRepository extends BaseAnkiRepository {
  AnkiSettings _settings = const AnkiSettings();

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings settings) async =>
      _settings = settings;

  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();
}

void main() {
  late Directory tmp;
  late Directory oldDocs;
  late Directory oldSupport;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_pathgap_');
    oldDocs = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    oldSupport = Directory(p.join(tmp.path, 'support'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String docs(List<String> segments) =>
      p.joinAll(<String>[oldDocs.path, ...segments]);

  /// 铺一份「每个漏项各有一条数据」的旧库。返回外部路径常量供断言复用。
  Future<void> seed(String dbDir) async {
    for (final String rel in <String>[
      p.join('game_covers', 'g1.jpg'),
      p.join('video_covers', 'v1.jpg'),
      p.join('video_subtitles', 'ep01.ass'),
      p.join('hoshi_books', 'Bk', 'cover.jpg'),
      p.join('anime_downloads', 'content', '.keep'),
      p.join('custom_fonts', 'a.ttf'),
    ]) {
      File(docs(<String>[rel]))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      await db.upsertGalgame(GalgamesCompanion.insert(
        id: 'g1',
        name: 'Game One',
        exePath: p.join('E:', 'Games', 'g1', 'g1.exe'),
        workdir: p.join('E:', 'Games', 'g1'),
        addedAt: 1,
        coverPath: Value(docs(<String>['game_covers', 'g1.jpg'])),
      ));
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/V1',
        title: 'V1',
        videoPath: p.join('E:', 'anime', 'V1.mkv'),
        coverPath: Value(docs(<String>['video_covers', 'v1.jpg'])),
        subtitleSource: Value(docs(<String>['video_subtitles', 'ep01.ass'])),
        secondarySubtitleSource: const Value('embedded:2'),
      ));
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/V2',
        title: 'V2',
        videoPath: p.join('E:', 'anime', 'V2.mkv'),
        subtitleSource: const Value('off:'),
      ));
      await db.upsertMediaItem(MediaItemsCompanion.insert(
        mediaIdentifier: 'Bk',
        title: 'Bk',
        mediaTypeIdentifier: 'reader_media_type',
        mediaSourceIdentifier: 'reader_hibiki',
        uniqueKey: 'reader/Bk',
        imageUrl: Value(
            Uri.file(docs(<String>['hoshi_books', 'Bk', 'cover.jpg']))
                .toString()),
        position: 0,
        duration: 0,
        canDelete: true,
        canEdit: true,
      ));
      await db.upsertMediaItem(MediaItemsCompanion.insert(
        mediaIdentifier: 'Remote',
        title: 'Remote',
        mediaTypeIdentifier: 'reader_media_type',
        mediaSourceIdentifier: 'remote',
        uniqueKey: 'reader/Remote',
        imageUrl: const Value('https://example.com/cover.jpg'),
        position: 0,
        duration: 0,
        canDelete: true,
        canEdit: true,
      ));
      await db.setPref(
        'galgame_library',
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'g1',
            'exePath': p.join('E:', 'Games', 'g1', 'g1.exe'),
            'coverPath': docs(<String>['game_covers', 'g1.jpg']),
          }
        ]),
      );
      await db.setPref(
        'video_remote_subtitle',
        jsonEncode(<String, String>{
          'remote/1#ep0': docs(<String>['video_subtitles', 'ep01.ass']),
          'remote/2#ep0': 'embedded:1',
          'remote/3#ep0': 'off:',
        }),
      );
      await db.setPref(
          'download_save_root', docs(<String>['anime_downloads', 'content']));
      await db.setPref(
        'download_save_root_history',
        jsonEncode(<String>[
          docs(<String>['anime_downloads', 'content']),
          p.join('F:', 'downloads'),
        ]),
      );
      await db.setPref(
          'local_audio_db_path', p.join(dbDir, 'local_audio_1.db'));
      await db.setPref('video_mpv_shader_dir', p.join('G:', 'mpv', 'shaders'));
      await db.setPref(
        'src:reader_fushi:font_catalog',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'fonts': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'f1',
              'name': 'A',
              'path': docs(<String>['custom_fonts', 'a.ttf']),
            }
          ],
        }),
      );
    } finally {
      await db.close();
    }
  }

  /// 读回一份「路径快照」：所有被改写的字段的当前值，用来做等值断言与幂等断言。
  Future<Map<String, String?>> snapshot(String dbDir) async {
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final Map<String, String?> out = <String, String?>{};
      final GalgameRow g = (await db.getAllGalgames()).single;
      out['galgames.coverPath'] = g.coverPath;
      out['galgames.exePath'] = g.exePath;
      for (final VideoBookRow v in await db.allVideoBooks()) {
        out['video.${v.bookUid}.cover'] = v.coverPath;
        out['video.${v.bookUid}.sub'] = v.subtitleSource;
        out['video.${v.bookUid}.sub2'] = v.secondarySubtitleSource;
        out['video.${v.bookUid}.path'] = v.videoPath;
      }
      for (final MediaItemRow m in await db.getAllMediaItems()) {
        out['media.${m.uniqueKey}.image'] = m.imageUrl;
      }
      final Map<String, String> prefs = await db.getAllPrefs();
      for (final String key in <String>[
        'galgame_library',
        'video_remote_subtitle',
        'download_save_root',
        'download_save_root_history',
        'local_audio_db_path',
        'video_mpv_shader_dir',
        'src:reader_fushi:font_catalog',
      ]) {
        out['pref.$key'] = prefs[key];
      }
      final List<QueryRow> rows = await db
          .customSelect(
              "SELECT key, value FROM profile_settings WHERE category = 'pref'")
          .get();
      for (final QueryRow r in rows) {
        out['profile.${r.read<String>('key')}'] = r.read<String>('value');
      }
      return out;
    } finally {
      await db.close();
    }
  }

  /// 断言快照里的每个数据根内路径都指向 [newDocs]，且外部路径纹丝不动。
  void expectRebasedOnto(Map<String, String?> snap, String newDocs) {
    String at(List<String> segments) =>
        p.joinAll(<String>[newDocs, ...segments]);

    expect(snap['galgames.coverPath'],
        equals(at(<String>['game_covers', 'g1.jpg'])));
    expect(
        snap['galgames.exePath'], equals(p.join('E:', 'Games', 'g1', 'g1.exe')),
        reason: '外部游戏安装位置绝不能被改写');
    expect(snap['video.video/V1.cover'],
        equals(at(<String>['video_covers', 'v1.jpg'])));
    expect(snap['video.video/V1.sub'],
        equals(at(<String>['video_subtitles', 'ep01.ass'])));
    expect(snap['video.video/V1.sub2'], equals('embedded:2'),
        reason: 'embedded: 哨兵必须原样保留');
    expect(snap['video.video/V2.sub'], equals('off:'), reason: 'off: 哨兵必须原样保留');
    expect(snap['video.video/V1.path'], equals(p.join('E:', 'anime', 'V1.mkv')),
        reason: '用户原位外部视频不该被改写');
    expect(
        snap['media.reader/Bk.image'],
        equals(Uri.file(at(<String>['hoshi_books', 'Bk', 'cover.jpg']))
            .toString()));
    expect(snap['media.reader/Remote.image'],
        equals('https://example.com/cover.jpg'),
        reason: '远端 http 封面不是 file: URI，必须原样返回');

    final List<dynamic> games =
        jsonDecode(snap['pref.galgame_library']!) as List<dynamic>;
    expect((games.single as Map<String, dynamic>)['coverPath'],
        equals(at(<String>['game_covers', 'g1.jpg'])));
    expect((games.single as Map<String, dynamic>)['exePath'],
        equals(p.join('E:', 'Games', 'g1', 'g1.exe')));

    final Map<String, dynamic> remote =
        jsonDecode(snap['pref.video_remote_subtitle']!) as Map<String, dynamic>;
    expect(remote['remote/1#ep0'],
        equals(at(<String>['video_subtitles', 'ep01.ass'])));
    expect(remote['remote/2#ep0'], equals('embedded:1'));
    expect(remote['remote/3#ep0'], equals('off:'));

    expect(snap['pref.download_save_root'],
        equals(at(<String>['anime_downloads', 'content'])));
    final List<dynamic> history =
        jsonDecode(snap['pref.download_save_root_history']!) as List<dynamic>;
    expect(history.first, equals(at(<String>['anime_downloads', 'content'])));
    expect(history.last, equals(p.join('F:', 'downloads')),
        reason: '外部盘的历史根不该被改写');

    expect(snap['pref.video_mpv_shader_dir'],
        equals(p.join('G:', 'mpv', 'shaders')),
        reason: '用户外部 mpv 目录绝不能被改写');

    final Map<String, dynamic> catalog =
        jsonDecode(snap['pref.src:reader_fushi:font_catalog']!)
            as Map<String, dynamic>;
    expect((catalog['fonts'] as List<dynamic>).single['path'],
        equals(at(<String>['custom_fonts', 'a.ttf'])));
  }

  test('① 迁移改写了全部漏项，外部路径纹丝不动', () async {
    await seed(oldSupport.path);
    final String newDataRoot = p.join(tmp.path, 'newroot');
    final List<String> prefWrites = <String>[];
    final (Directory newDocs, Directory newSupport) =
        await const DataRootMigrator().migrate(DataRootMigrationRequest(
      oldDocumentsRoot: oldDocs,
      oldSupportRoot: oldSupport,
      target: DataRootMigrationTarget.customRoot(newDataRoot),
      closeResources: () async {},
      commitLocation: (DataRootMigrationTarget t) async =>
          prefWrites.add(t.dataRootPrefValue!),
      documentsTopLevelIncludeNames: AppPaths.fushiOwnedDocumentsEntries,
    ));
    expect(prefWrites, equals(<String>[newDataRoot]));
    expectRebasedOnto(await snapshot(newSupport.path), newDocs.path);
  });

  test('② 迁移后「切 Profile」不会把路径退回旧值', () async {
    await seed(oldSupport.path);
    // 先造一个 Profile 并快照当前（旧根）prefs —— 这正是用户迁移前的真实状态。
    final FushiDatabase pre = FushiDatabase(oldSupport.path);
    late int profileId;
    try {
      final ProfileRepository repo =
          ProfileRepository(pre, _FakeAnkiRepository());
      profileId = await repo.createProfile('P1');
      await repo.snapshotCurrentSettings(profileId);
      // 前提：快照里确实存着旧根绝对路径。用 video_remote_subtitle（会进快照）；
      // download_save_root* 被 ProfileKeys.isExcludedPref 挡在快照外（设备本地键），
      // 所以它们只需改 preferences，不会被切 Profile 写回——这一点一并钉死。
      final List<QueryRow> rows = await pre
          .customSelect(
              "SELECT key, value FROM profile_settings WHERE category = 'pref' "
              "AND key IN ('video_remote_subtitle', 'src:reader_fushi:font_catalog', "
              "'download_save_root')")
          .get();
      final Map<String, String> snapshotted = <String, String>{
        for (final QueryRow r in rows)
          r.read<String>('key'): r.read<String>('value'),
      };
      expect(
          snapshotted.keys.toSet(),
          equals(<String>{
            'video_remote_subtitle',
            'src:reader_fushi:font_catalog'
          }),
          reason: 'download_save_root 是设备本地键，按设计不进 Profile 快照');
      expect(jsonDecode(snapshotted['video_remote_subtitle']!)['remote/1#ep0'],
          equals(docs(<String>['video_subtitles', 'ep01.ass'])),
          reason: '前提：快照里确实存着旧根绝对路径');
    } finally {
      await pre.close();
    }

    final String newDataRoot = p.join(tmp.path, 'newroot');
    final (Directory newDocs, Directory newSupport) =
        await const DataRootMigrator().migrate(DataRootMigrationRequest(
      oldDocumentsRoot: oldDocs,
      oldSupportRoot: oldSupport,
      target: DataRootMigrationTarget.customRoot(newDataRoot),
      closeResources: () async {},
      commitLocation: (DataRootMigrationTarget t) async {},
      documentsTopLevelIncludeNames: AppPaths.fushiOwnedDocumentsEntries,
    ));

    // 真正走一次 applyProfile（= 用户切 Profile），再看 live prefs 有没有被写回旧根。
    final FushiDatabase post = FushiDatabase(newSupport.path);
    try {
      final ProfileRepository repo =
          ProfileRepository(post, _FakeAnkiRepository());
      await repo.applyProfile(profileId);
      final Map<String, String> prefs = await post.getAllPrefs();
      expect(
        prefs['download_save_root'],
        equals(p.join(newDocs.path, 'anime_downloads', 'content')),
        reason: '设备本地键不进快照，切 Profile 后仍是迁移后的新值',
      );
      expect(
        (jsonDecode(prefs['src:reader_fushi:font_catalog']!)
            as Map<String, dynamic>)['fonts'][0]['path'],
        equals(p.join(newDocs.path, 'custom_fonts', 'a.ttf')),
      );
      expect(
        jsonDecode(prefs['video_remote_subtitle']!)['remote/1#ep0'],
        equals(p.join(newDocs.path, 'video_subtitles', 'ep01.ass')),
        reason: 'BUG-1174 ②：切 Profile 把 profile_settings 快照原样写回 preferences，'
            '快照没被 rebase 的话刚迁好的路径会整体回滚到旧根——迁移当天一切正常，'
            '几天后用户切一次 Profile 才突然坏，极难归因',
      );
      expect(
        jsonDecode(prefs['galgame_library']!).single['coverPath'],
        equals(p.join(newDocs.path, 'game_covers', 'g1.jpg')),
      );
    } finally {
      await post.close();
    }
  });

  test('③ 新根落在旧根内部时，同一改写连跑两次是 no-op（不会 Hibiki/data/Hibiki/data）', () async {
    await seed(oldSupport.path);
    // 正是 BUG-1115 的形态：newDocs 就在 oldDocs 里面。旧的 startsWith(oldRoot) 判据
    // 会把已改写过的路径再改一遍，产出 .../Hibiki/data/Hibiki/data/...，静默毁全库。
    final String newDocs = p.joinAll(
        <String>[oldDocs.path, ...AppPaths.defaultDocumentsChildSegments]);
    Future<void> runOnce() =>
        const DataRootMigrator().rebaseDatabasePathsForTesting(
          dbDirectory: oldSupport.path,
          oldDocumentsRoot: oldDocs.path,
          newDocumentsRoot: newDocs,
          newSupportRoot: oldSupport.path,
          documentsScopeEntries: AppPaths.fushiOwnedDocumentsEntries,
        );

    await runOnce();
    final Map<String, String?> first = await snapshot(oldSupport.path);
    expectRebasedOnto(first, newDocs);

    await runOnce();
    final Map<String, String?> second = await snapshot(oldSupport.path);
    expect(second, equals(first), reason: '第二遍必须是逐字节 no-op');
    expectRebasedOnto(second, newDocs);

    // 显式钉死「双重嵌套」这个具体症状。
    final String doubled = p.joinAll(<String>[
      newDocs,
      ...AppPaths.defaultDocumentsChildSegments,
    ]);
    for (final MapEntry<String, String?> e in second.entries) {
      expect(e.value ?? '', isNot(contains(doubled)), reason: e.key);
    }
  });

  test('③b 作用域谓词：首段不在白名单里的路径不参与改写', () {
    const DocumentsPathRebaser rebaser = DocumentsPathRebaser(
      oldRoot: '/home/u/Documents',
      newRoot: '/home/u/Documents/Hibiki/data',
      scopeTopLevelNames: AppPaths.fushiOwnedDocumentsEntries,
    );
    expect(rebaser.rebase('/home/u/Documents/audiobooks/a.mp3'),
        equals('/home/u/Documents/Hibiki/data/audiobooks/a.mp3'));
    // 已改写过的路径：首段是 Hibiki（不在白名单）→ 原样返回 = 幂等。
    expect(rebaser.rebase('/home/u/Documents/Hibiki/data/audiobooks/a.mp3'),
        equals('/home/u/Documents/Hibiki/data/audiobooks/a.mp3'));
    // 用户自己的文件：不搬也不改。
    expect(rebaser.rebase('/home/u/Documents/thesis.docx'),
        equals('/home/u/Documents/thesis.docx'));
    // 白名单项的前缀撞名不算命中（边界必须是分隔符）。
    expect(rebaser.rebase('/home/u/Documents/videos_backup/x.mkv'),
        equals('/home/u/Documents/videos_backup/x.mkv'));
    // 大小写不敏感：hibikiExport 在 Windows 上会被搬走，路径必须一起改。
    expect(rebaser.rebase('/home/u/Documents/HibikiExport/card.jpg'),
        equals('/home/u/Documents/Hibiki/data/HibikiExport/card.jpg'));
    // 根本体本身。
    expect(rebaser.rebase('/home/u/Documents'),
        equals('/home/u/Documents/Hibiki/data'));
  });

  test('③c 整树搬移（无白名单）仍改写全部子路径', () {
    const DocumentsPathRebaser rebaser = DocumentsPathRebaser(
      oldRoot: '/old/documents',
      newRoot: '/new/documents',
      scopeTopLevelNames: null,
    );
    expect(rebaser.rebase('/old/documents/anything/deep/x'),
        equals('/new/documents/anything/deep/x'));
    expect(rebaser.rebase('/elsewhere/x'), equals('/elsewhere/x'));
  });

  test('④ 改写中途失败：整段回滚，不留半改状态', () async {
    await seed(oldSupport.path);
    final Map<String, String?> before = await snapshot(oldSupport.path);
    DataRootMigrator.debugFailMidRebase = true;
    try {
      await expectLater(
        const DataRootMigrator().rebaseDatabasePathsForTesting(
          dbDirectory: oldSupport.path,
          oldDocumentsRoot: oldDocs.path,
          newDocumentsRoot: p.join(tmp.path, 'newroot', 'documents'),
          newSupportRoot: oldSupport.path,
          documentsScopeEntries: AppPaths.fushiOwnedDocumentsEntries,
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      DataRootMigrator.debugFailMidRebase = false;
    }
    expect(await snapshot(oldSupport.path), equals(before),
        reason: 'BUG-1174 ④：改写必须在单事务里，中途失败整体回滚。逐行 UPDATE 的旧写法'
            '会留下「一半指新根、一半指旧根」的库，而外层回滚只搬文件、救不了半改的 DB');
  });

  test('rebaseMigratedPrefValue 不动未登记的 key（profile_settings 里躺着全部 pref）', () {
    const DocumentsPathRebaser rebaser = DocumentsPathRebaser(
      oldRoot: '/home/u/Documents',
      newRoot: '/home/u/Documents/Hibiki/data',
      scopeTopLevelNames: AppPaths.fushiOwnedDocumentsEntries,
    );
    for (final String key in <String>[
      'theme_mode',
      'video_mpv_shader_dir',
      'manga_external_mokuro_path',
    ]) {
      expect(
        rebaseMigratedPrefValue(
            key, '/home/u/Documents/audiobooks/looks_like_a_path',
            documents: rebaser, newSupportRoot: '/support'),
        equals('/home/u/Documents/audiobooks/looks_like_a_path'),
        reason: key,
      );
    }
    expect(pathRebasePrefFor('theme_mode'), isNull);
  });
}
