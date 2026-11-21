import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi/src/onboarding/recommended_pack_import.dart'
    show kRecommendedPackImportMode;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show BackupImportMode, BackupImportPreset, backupImportPresetCategories;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-4698：导入推荐包后用户的漫画 / 小说全没了。
///
/// 推荐包是一份净化过的备份（只剩 `dictionary_metadata`、两条音频来源注册偏好与
/// 词典资源 / 本地发音库文件，见 `tool/pack/recommended_pack_database.dart`）。app 内
/// 入口以前弹默认「覆盖」的通用导入框，整库被替换。现在确认框预选
/// [kRecommendedPackImportMode]（合并），分类默认全勾。这里按同一套规则折算出的分类跑真实的
/// [BackupRestoreService.mergeRestoreBackup]：书库行与进度原样保留（bookKey / uid 不变），
/// 推荐包的词典与发音库全部装上——包括设备已经有自己的音频来源列表时，发音库也要
/// 注册进去（以前合并只在本机列表为空时才收包里的列表，于是文件拷进来了却没登记）。
void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('rpack_merge_');
  });
  tearDown(() => cleanupTempDir(root));

  /// 造一份推荐包形状的备份 zip：一本词典 + 一个本地发音库及其注册项。
  Future<String> buildPackZip() async {
    final String srcDbDir = p.join(root.path, 'pack_src', 'support');
    final String srcDictDir = p.join(root.path, 'pack_src', 'dict');
    Directory(srcDbDir).createSync(recursive: true);
    Directory(p.join(srcDictDir, 'JMdict')).createSync(recursive: true);
    File(
      p.join(srcDictDir, 'JMdict', 'index.json'),
    ).writeAsStringSync('{"title":"JMdict"}');
    final String srcLadb = p.join(srcDbDir, 'local_audio_123.db');
    File(srcLadb).writeAsStringSync('PACK_AUDIO');
    final String srcLadbJson = srcLadb.replaceAll(r'\', r'\\');

    final FushiDatabase src = FushiDatabase(srcDbDir);
    await src.upsertDictionaryMeta(
      DictionaryMetadataCompanion.insert(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 0,
      ),
    );
    await src.setPref(
      'local_audio_dbs',
      's:[{"path":"$srcLadbJson","displayName":"Pack audio","enabled":true}]',
    );
    await src.setPref(
      'audio_source_configs',
      'j:[{"kind":"fushiRemote","enabled":true},'
          '{"kind":"localAudio","enabled":true,"label":"Pack audio",'
          '"path":"$srcLadbJson"}]',
    );
    final String zip = p.join(root.path, 'pack.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDbDir,
      dictionaryResourceDirectory: srcDictDir,
      appVersion: '2.0.0',
    ).createBackup(zip);
    await src.close();
    return zip;
  }

  // 确认框预选合并、分类全勾（不碰任何开关直接确认）折算出的就是这份预设。
  const BackupImportPreset packDefault = BackupImportPreset(
    mode: kRecommendedPackImportMode,
  );

  test('recommended pack import preselects merge', () {
    expect(kRecommendedPackImportMode, BackupImportMode.merge);
  });

  test('merging the recommended pack keeps the library and installs every '
      'dictionary / audio resource', () async {
    final String zip = await buildPackZip();

    // ── 用户设备：一本小说 + 阅读进度 + 自己的音频来源（含一个本地发音库）。
    final String curDbDir = p.join(root.path, 'device', 'support');
    final String curDictDir = p.join(root.path, 'device', 'dict');
    Directory(curDbDir).createSync(recursive: true);
    Directory(curDictDir).createSync(recursive: true);
    final String ownLadb = p.join(curDbDir, 'local_audio_999.db');
    File(ownLadb).writeAsStringSync('OWN_AUDIO');
    final String ownLadbJson = ownLadb.replaceAll(r'\', r'\\');
    final FushiDatabase seed = FushiDatabase(curDbDir);
    await seed.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'MyNovel',
        title: 'My novel',
        epubPath: 'x',
        extractDir: 'y',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ),
    );
    final String bookUid = (await seed.resolveEpubBookUid('MyNovel'))!;
    await seed.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: bookUid,
        sectionIndex: 3,
        normCharOffset: 1234,
        updatedAt: 1,
      ),
    );
    await seed.setPref(
      'local_audio_dbs',
      's:[{"path":"$ownLadbJson","displayName":"Own","enabled":true}]',
    );
    await seed.setPref(
      'audio_source_configs',
      'j:[{"kind":"fushiRemote","enabled":true},'
          '{"kind":"remoteAudio","enabled":true,"label":"Mine",'
          '"url":"https://audio.example/{term}"},'
          '{"kind":"localAudio","enabled":true,"label":"Own",'
          '"path":"$ownLadbJson"}]',
    );
    await seed.close();

    final BackupContentSummary summary =
        await BackupRestoreService.summarizeBackupFile(zip);
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: backupImportPresetCategories(packDefault, summary),
      dictionaryResourceDirectory: curDictDir,
    );

    final FushiDatabase cur = FushiDatabase(curDbDir);

    // 书库行与进度：原样保留，bookKey → uid 不变（卡片来源靠它连回书）。
    final List<QueryRow> books = await cur
        .customSelect('SELECT book_key, uid FROM epub_books')
        .get();
    expect(books, hasLength(1));
    expect(books.single.data['book_key'], 'MyNovel');
    expect(books.single.data['uid'], bookUid);
    final List<QueryRow> positions = await cur
        .customSelect(
          'SELECT section_index, norm_char_offset FROM reader_positions '
          'WHERE book_uid = ?',
          variables: <Variable<Object>>[Variable<String>(bookUid)],
        )
        .get();
    expect(positions, hasLength(1));
    expect(positions.single.data['section_index'], 3);
    expect(positions.single.data['norm_char_offset'], 1234);

    // 词典：元数据行 + 资源文件都装上。
    final List<QueryRow> dicts = await cur
        .customSelect('SELECT name FROM dictionary_metadata')
        .get();
    expect(dicts.map((QueryRow r) => r.data['name']), contains('JMdict'));
    expect(
      File(p.join(curDictDir, 'JMdict', 'index.json')).existsSync(),
      isTrue,
    );

    // 发音库：文件拷进来，且两份注册项都在本机原有条目之后追加了它；本机自己的
    // 条目（含远程来源与本机发音库）一个不少、文件不被覆盖。
    expect(
      File(p.join(curDbDir, 'local_audio_123.db')).readAsStringSync(),
      'PACK_AUDIO',
    );
    expect(File(ownLadb).readAsStringSync(), 'OWN_AUDIO');
    final String localAudio = (await cur.getPref('local_audio_dbs'))!;
    final String audioCfg = (await cur.getPref('audio_source_configs'))!;
    expect(localAudio, startsWith('s:'));
    expect(audioCfg, startsWith('j:'));
    expect(localAudio, contains('local_audio_999.db'));
    expect(localAudio, contains('local_audio_123.db'));
    expect(
      localAudio.indexOf('local_audio_999.db'),
      lessThan(localAudio.indexOf('local_audio_123.db')),
    );
    expect(audioCfg, contains('https://audio.example/{term}'));
    expect(audioCfg, contains('local_audio_999.db'));
    expect(audioCfg, contains('local_audio_123.db'));
    // 包里的 fushiRemote 不重复追加（非本地发音库条目是本机设置，合并不收）。
    expect('fushiRemote'.allMatches(audioCfg), hasLength(1));
    // 追加的条目路径已重挂到本机支持目录，不再指向打包机。
    String flat(String s) => s.replaceAll(r'\\', '/').replaceAll(r'\', '/');
    expect(flat(audioCfg), isNot(contains('pack_src')));
    expect(flat(localAudio), isNot(contains('pack_src')));

    // 同一个包再合并一次：幂等，不重复登记。
    await cur.close();
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: backupImportPresetCategories(packDefault, summary),
      dictionaryResourceDirectory: curDictDir,
    );
    final FushiDatabase again = FushiDatabase(curDbDir);
    addTearDown(again.close);
    expect(
      'local_audio_123.db'.allMatches(
        (await again.getPref('audio_source_configs'))!,
      ),
      hasLength(1),
    );
    expect(
      'local_audio_123.db'.allMatches(
        (await again.getPref('local_audio_dbs'))!,
      ),
      hasLength(1),
    );
  });
}
