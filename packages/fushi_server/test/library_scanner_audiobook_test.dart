import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端有声书根（kind=audiobook）：含音频的目录 / 散放音频文件各算一本，交给引擎
/// 同一套有声书判据入库；音频引用导入（不拷进数据目录）；源目录消失后对账回收。
const String _kSrt =
    '1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n\n'
    '2\n00:00:02,000 --> 00:00:04,000\n名前はまだ無い。\n';

void _write(String path, [List<int> bytes = const <int>[7, 7, 7, 7]]) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

void _writeText(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

void main() {
  late Directory tmp;
  late Directory root;
  late ServerPaths paths;
  late FushiDatabase db;
  late LibraryScanner scanner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_audiobook_');
    root = Directory(p.join(tmp.path, 'audiobooks_root'))..createSync();
    paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    // 与生产同一个装配入口：有声书持久根 / 书目录根都落在 data 目录下。
    installServerHostBindings(
      config: ServerConfig.defaults(dataDir: paths.dataDir),
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
    );
    EpubStorage.debugBaseDirectoryOverride = null;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    scanner = LibraryScanner(
      db: db,
      subtitleLanguage: 'ja',
      extractCovers: false,
    );
  });

  tearDown(() async {
    await db.close();
    engineLog = const StderrEngineLogSink();
    enginePaths = const UninstalledEnginePaths();
    AudiobookStorage.documentsRootResolver = null;
    EpubStorage.debugBaseDirectoryOverride = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<ScanSummary> scan() => scanner.scanAll(<LibraryRootConfig>[
    LibraryRootConfig(id: 'ab', path: root.path, kind: 'audiobook'),
  ]);

  String rel(String path) =>
      p.relative(path, from: root.path).replaceAll(r'\', '/');

  test('划分：含音频的目录一本、分碟子目录并进上一层、散放音频各一本，.txt 不当正文', () {
    _write(p.join(root.path, 'BookA', '01.mp3'));
    _write(p.join(root.path, 'BookA', '02.mp3'));
    _writeText(p.join(root.path, 'BookA', 'BookA.srt'), _kSrt);
    _writeText(p.join(root.path, 'BookA', 'readme.txt'), 'not the body');
    _write(p.join(root.path, 'Author', 'BookB [B000000001]', 'CD1', '01.mp3'));
    _write(p.join(root.path, 'Author', 'BookB [B000000001]', 'CD2', '01.mp3'));
    _writeText(
      p.join(root.path, 'Author', 'BookB [B000000001]', 'b.srt'),
      _kSrt,
    );
    _write(p.join(root.path, 'Loose.m4b'));
    _writeText(p.join(root.path, 'Loose.srt'), _kSrt);
    _writeText(p.join(root.path, 'Other.srt'), _kSrt);
    _writeText(p.join(root.path, 'NotABook', 'notes.txt'), 'x');

    final List<AudiobookFolder> folders = planAudiobookFolders(root);

    expect(folders.map((AudiobookFolder f) => rel(f.path)), <String>[
      'Author/BookB [B000000001]',
      'BookA',
      'Loose.m4b',
    ]);
    final AudiobookFolder bookB = folders[0];
    expect(bookB.title, 'BookB');
    expect(bookB.files.map(rel), <String>[
      'Author/BookB [B000000001]/CD1/01.mp3',
      'Author/BookB [B000000001]/CD2/01.mp3',
      'Author/BookB [B000000001]/b.srt',
    ]);
    expect(folders[1].files.map(rel), <String>[
      'BookA/01.mp3',
      'BookA/02.mp3',
      'BookA/BookA.srt',
    ]);
    expect(folders[2].title, 'Loose');
    expect(folders[2].files.map(rel), <String>['Loose.m4b', 'Loose.srt']);
  });

  test('字幕 + 音频成独立字幕书，只有音频的不导入；音频引用原路径；重扫不再导入', () async {
    _write(p.join(root.path, 'Neko', '01.mp3'));
    _writeText(p.join(root.path, 'Neko', 'neko.srt'), _kSrt);
    _write(p.join(root.path, 'AudioOnly', '01.mp3'));

    final ScanSummary first = await scan();

    expect(first.errors, isEmpty);
    expect(first.audiobooksAdded, 1);
    expect(first.audiobooksNeedSubtitle, 1);
    final MediaSourceRow? source =
        await LibraryScanner.findLocalSourceByMediaKind(
          db,
          root.path,
          kAudiobookSourceMediaKind,
        );
    expect(source, isNotNull);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books, hasLength(1));
    expect(books.single.sourceId, source!.id);
    final SrtBookRow? srt = await db.getSrtBookByBookKey(books.single.bookKey);
    expect(srt, isNotNull);
    expect(srt!.audioPathsJson, contains('01.mp3'));
    expect(
      srt.audioPathsJson,
      contains(p.join(root.path, 'Neko').replaceAll(r'\', r'\\')),
      reason: '库根里的音频是引用导入，不拷进数据目录',
    );

    final ScanSummary second = await scan();
    expect(second.audiobooksAdded, 0);
    expect(second.audiobooksSkipped, 1);
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('EPUB + 字幕 + 音频走对齐落库：有声书行引用库根里的音频', () async {
    final File txt = File(p.join(tmp.path, 'neko.txt'))
      ..writeAsStringSync('吾輩は猫である。\n\n名前はまだ無い。\n');
    final Uint8List epub = await TextToEpub.convert(file: txt, title: 'Neko');
    _write(p.join(root.path, 'Neko', 'Neko.epub'), epub);
    _writeText(p.join(root.path, 'Neko', 'neko.srt'), _kSrt);
    _write(p.join(root.path, 'Neko', 'neko.mp3'));

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.audiobooksAdded, 1);
    final List<AudiobookRow> audiobooks = await db.getAllAudiobooks();
    expect(audiobooks, hasLength(1));
    expect(
      audiobooks.single.audioPathsJson,
      contains(p.join(root.path, 'Neko', 'neko.mp3').replaceAll(r'\', r'\\')),
    );
    final EpubBookRow? book = await db.getEpubBook(audiobooks.single.bookKey);
    expect(book?.sourceId, isNotNull);
  });

  test('书目录删掉后重扫回收那本，留下的照旧；持久目录一并回收、库根音频不碰', () async {
    _write(p.join(root.path, 'Keep', '01.mp3'));
    _writeText(p.join(root.path, 'Keep', 'keep.srt'), _kSrt);
    _write(p.join(root.path, 'Drop', '01.mp3'));
    _writeText(p.join(root.path, 'Drop', 'drop.srt'), _kSrt);
    expect((await scan()).audiobooksAdded, 2);
    final SrtBookRow dropSrt = (await db.getAllSrtBooks()).firstWhere(
      (SrtBookRow r) => r.title == 'Drop',
    );
    final String persistRoot = await AudiobookStorage.audiobooksRootDir();
    final int persistDirsBefore = Directory(persistRoot).listSync().length;

    Directory(p.join(root.path, 'Drop')).deleteSync(recursive: true);
    // 两本删一本 = 50%，越过默认比例护栏：按「显式放行」跑。
    final ScanSummary summary =
        await LibraryScanner(
          db: db,
          subtitleLanguage: 'ja',
          extractCovers: false,
          pruneForce: true,
        ).scanAll(<LibraryRootConfig>[
          LibraryRootConfig(id: 'ab', path: root.path, kind: 'audiobook'),
        ]);

    expect(summary.errors, isEmpty);
    expect(summary.audiobooksPruned, 1);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title), <String>['Keep']);
    expect(await db.getSrtBookByUid(dropSrt.uid), isNull);
    expect(Directory(persistRoot).listSync(), hasLength(persistDirsBefore - 1));
    expect(File(p.join(root.path, 'Keep', '01.mp3')).existsSync(), isTrue);
  });

  // ── 已导入目录的就地更新（补章节 / 换字幕 / 删分段 / 不变时零写入）──────────

  const String srtV2 =
      '1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n\n'
      '2\n00:00:02,000 --> 00:00:04,000\n名前はまだ無い。\n\n'
      '3\n00:00:04,000 --> 00:00:06,000\nどこで生れたかとんと見当がつかぬ。\n';

  Future<SrtBook> standalone(String title) async {
    final SrtBookRow row = (await db.getAllSrtBooks()).singleWhere(
      (SrtBookRow r) => r.title == title,
    );
    return (await SrtBookRepository(db).findByUid(row.uid))!;
  }

  Future<List<String>> persistedSubtitles(String key) async {
    final Directory dir = await AudiobookStorage.ensurePersistDir(key);
    return <String>[
      for (final FileSystemEntity e in dir.listSync())
        if (e is File && e.path.endsWith('.srt')) p.basename(e.path),
    ];
  }

  test('独立字幕书目录补分段 → 重扫按自然序就地加进清单，进度与身份不变；删断点之后的分段'
      '跟着删、进度保留，删掉断点所在的分段进度归零', () async {
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, 'Part 1.mp3'));
    _write(p.join(book, 'Part 10.mp3'));
    _writeText(p.join(book, 'neko.srt'), _kSrt);
    expect((await scan()).audiobooksAdded, 1);
    final SrtBook before = await standalone('Neko');
    final AudiobookRepository positions = AudiobookRepository(db);
    await positions.updatePositionMs(bookKey: before.uid, positionMs: 1500);

    _write(p.join(book, 'Part 2.mp3'));
    final ScanSummary added = await scan();

    expect(added.errors, isEmpty);
    expect(added.audiobooksUpdated, 1);
    expect(added.audiobooksAdded, 0);
    expect(added.audiobooksNeedSubtitle, 0, reason: '已导入的书补进没字幕的分段不算「缺字幕」');
    SrtBook after = await standalone('Neko');
    expect(after.uid, before.uid, reason: '就地更新，不是删了重导');
    expect(after.importedAt, before.importedAt);
    expect(after.audioPaths, <String>[
      p.join(book, 'Part 1.mp3'),
      p.join(book, 'Part 2.mp3'),
      p.join(book, 'Part 10.mp3'),
    ]);
    expect(await db.getAllEpubBooks(), hasLength(1));
    expect(await positions.readPositionMs(before.uid), 1500);

    File(p.join(book, 'Part 10.mp3')).deleteSync();
    expect((await scan()).audiobooksUpdated, 1);
    after = await standalone('Neko');
    expect(after.audioPaths, <String>[
      p.join(book, 'Part 1.mp3'),
      p.join(book, 'Part 2.mp3'),
    ]);
    expect(await positions.readPositionMs(before.uid), 1500);

    File(p.join(book, 'Part 1.mp3')).deleteSync();
    expect((await scan()).audiobooksUpdated, 1);
    expect((await standalone('Neko')).audioPaths, <String>[
      p.join(book, 'Part 2.mp3'),
    ]);
    expect(
      await positions.readPositionMs(before.uid),
      0,
      reason: '断点所在的文件没了，同一个毫秒数指向别的声音（BUG-1679）',
    );
  });

  test('独立字幕书目录换字幕 → 重扫换 cue、重建正文，持久目录只留新副本', () async {
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, '01.mp3'));
    _writeText(p.join(book, 'neko.srt'), _kSrt);
    await scan();
    final SrtBook before = await standalone('Neko');
    expect(await SrtBookRepository(db).cuesFor(before.uid), hasLength(2));

    _writeText(p.join(book, 'neko.srt'), srtV2);
    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.audiobooksUpdated, 1);
    final List<AudioCue> cues = await SrtBookRepository(db).cuesFor(before.uid);
    expect(cues.map((AudioCue c) => c.text), contains('どこで生れたかとんと見当がつかぬ。'));
    expect(await persistedSubtitles(before.uid), hasLength(1));
    expect((await standalone('Neko')).audioPaths, <String>[
      p.join(book, '01.mp3'),
    ]);
    // 阅读器按文本相等把 cue 配回正文：正文必须按新 cue 重建。
    final EpubBookRow body = (await db.getEpubBook(before.bookKey))!;
    final String bodyText = <String>[
      for (final FileSystemEntity e in Directory(
        body.extractDir,
      ).listSync(recursive: true))
        if (e is File && e.path.endsWith('html')) e.readAsStringSync(),
    ].join();
    expect(bodyText, contains('どこで生れたかとんと見当がつかぬ。'));
  });

  test('EPUB 有声书目录补分段、再换字幕 → 有声书行与配对字幕书一起更新，旧字幕副本回收', () async {
    final File txt = File(p.join(tmp.path, 'neko.txt'))
      ..writeAsStringSync('吾輩は猫である。\n\n名前はまだ無い。\n\nどこで生れたかとんと見当がつかぬ。\n');
    final Uint8List epub = await TextToEpub.convert(file: txt, title: 'Neko');
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, 'Neko.epub'), epub);
    _writeText(p.join(book, 'neko.srt'), _kSrt);
    _write(p.join(book, '01.mp3'));
    expect((await scan()).audiobooksAdded, 1);
    final String bookKey = (await db.getAllAudiobooks()).single.bookKey;

    _write(p.join(book, '02.mp3'));
    final ScanSummary added = await scan();
    expect(added.errors, isEmpty);
    expect(added.audiobooksUpdated, 1);
    final List<String> both = <String>[
      p.join(book, '01.mp3'),
      p.join(book, '02.mp3'),
    ];
    expect(
      (await AudiobookRepository(db).findByBookKey(bookKey))!.audioPaths,
      both,
    );
    expect(
      (await SrtBookRepository(db).findByBookKey(bookKey))!.audioPaths,
      both,
    );
    expect(await AudiobookRepository(db).cuesForBook(bookKey), hasLength(2));

    _writeText(p.join(book, 'neko.srt'), srtV2);
    final ScanSummary replaced = await scan();
    expect(replaced.errors, isEmpty);
    expect(replaced.audiobooksUpdated, 1);
    expect(await AudiobookRepository(db).cuesForBook(bookKey), hasLength(3));
    expect(
      (await AudiobookRepository(db).findByBookKey(bookKey))!.audioPaths,
      both,
    );
    expect(
      await persistedSubtitles(bookKey),
      hasLength(1),
      reason: '换下的字幕副本不能越堆越多',
    );
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('目录没变：重扫不写库；旧版索引（没有签名）第一次重扫按字节比字幕、补记签名', () async {
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, '01.mp3'));
    _writeText(p.join(book, 'neko.srt'), _kSrt);
    await scan();
    final SrtBook before = await standalone('Neko');
    final int sourceId = (await LibraryScanner.findLocalSourceByMediaKind(
      db,
      root.path,
      kAudiobookSourceMediaKind,
    ))!.id;
    const String rel = 'Neko';
    expect(
      (await BookSourceIndex.load(db, sourceId)).signatureOf(rel),
      isNotNull,
    );

    final ScanSummary same = await scan();
    expect(same.audiobooksUpdated, 0);
    expect(same.audiobooksSkipped, 1);
    expect((await standalone('Neko')).importedAt, before.importedAt);

    // 模拟升级前导入的书：索引里只有认领、没有签名。
    final String uid = (await BookSourceIndex.load(db, sourceId)).uidOf(rel)!;
    Future<void> resetToLegacyIndex() async {
      await BookSourceIndex.clear(db, sourceId);
      await (BookSourceIndex.empty(sourceId)..put(rel, uid)).save(db);
    }

    await resetToLegacyIndex();
    final ScanSummary firstAfterUpgrade = await scan();
    expect(firstAfterUpgrade.audiobooksUpdated, 0, reason: '字幕与导入时的副本逐字节相同');
    expect(firstAfterUpgrade.audiobooksSkipped, 1);
    expect(
      (await BookSourceIndex.load(db, sourceId)).signatureOf(rel),
      isNotNull,
    );

    await resetToLegacyIndex();
    _writeText(p.join(book, 'neko.srt'), srtV2);
    expect((await scan()).audiobooksUpdated, 1);
    expect(await SrtBookRepository(db).cuesFor(before.uid), hasLength(3));
  });

  test('只有音频的目录后来放进字幕 → 下次扫描照常导入', () async {
    final String book = p.join(root.path, 'Later');
    _write(p.join(book, '01.mp3'));
    final ScanSummary first = await scan();
    expect(first.audiobooksNeedSubtitle, 1);
    expect(await db.getAllSrtBooks(), isEmpty);

    _writeText(p.join(book, 'later.srt'), _kSrt);
    final ScanSummary second = await scan();
    expect(second.audiobooksAdded, 1);
    expect(second.audiobooksNeedSubtitle, 0);
  });

  test('字幕解析不出 cue：记成错误、不落库，重扫不会一次次堆出空字幕书', () async {
    _write(p.join(root.path, 'Empty', '01.mp3'));
    _writeText(p.join(root.path, 'Empty', 'empty.srt'), 'not a subtitle\n');

    final ScanSummary first = await scan();
    expect(first.errors, hasLength(1));
    expect(first.audiobooksAdded, 0);
    await scan();
    expect(await db.getAllSrtBooks(), isEmpty);
  });

  // ── 多文件 + 一份单时间轴字幕：cue 按各文件实测时长分配（BUG-4248）──────────

  /// 换掉服务端装配的 ffprobe 探测：测试里的 mp3 是假字节，按文件名给时长。
  void fakeDurations(Map<String, int> byName) {
    AudiobookStorage.audioDurationProbeMs = (String path) async =>
        byName[p.basename(path)] ?? 0;
  }

  List<(int, int)> placement(List<AudioCue> cues) => <(int, int)>[
    for (final AudioCue c
        in List<AudioCue>.of(cues)..sort(
          (AudioCue a, AudioCue b) =>
              a.sentenceIndex.compareTo(b.sentenceIndex),
        ))
      (c.audioFileIndex, c.startMs),
  ];

  test('服务端装配了有声书时长探测（ffprobe），不再是全 0 的未装配状态', () {
    expect(AudiobookStorage.audioDurationProbeMs, isNotNull);
  });

  test('独立字幕书：两个文件导入时 cue 按时长分到各文件；补第三段重扫后重新分配', () async {
    fakeDurations(<String, int>{
      '01.mp3': 2000,
      '02.mp3': 2000,
      '03.mp3': 2000,
    });
    addTearDown(() => AudiobookStorage.audioDurationProbeMs = null);
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, '01.mp3'));
    _write(p.join(book, '02.mp3'));
    _writeText(p.join(book, 'neko.srt'), srtV2);

    expect((await scan()).audiobooksAdded, 1);
    final SrtBook imported = await standalone('Neko');
    expect(
      placement(await SrtBookRepository(db).cuesFor(imported.uid)),
      <(int, int)>[(0, 0), (1, 0), (1, 2000)],
      reason: '第 3 句起点在两段总长之后：夹在最后一个文件末尾，不丢句子',
    );

    _write(p.join(book, '03.mp3'));
    final ScanSummary added = await scan();
    expect(added.errors, isEmpty);
    expect(added.audiobooksUpdated, 1);
    expect(
      placement(await SrtBookRepository(db).cuesFor(imported.uid)),
      <(int, int)>[(0, 0), (1, 0), (2, 0)],
    );
  });

  test('EPUB 有声书：两个文件导入时 cue 按时长分到各文件；补第三段重扫后重新分配', () async {
    fakeDurations(<String, int>{
      '01.mp3': 2000,
      '02.mp3': 2000,
      '03.mp3': 2000,
    });
    addTearDown(() => AudiobookStorage.audioDurationProbeMs = null);
    final File txt = File(p.join(tmp.path, 'neko.txt'))
      ..writeAsStringSync('吾輩は猫である。\n\n名前はまだ無い。\n\nどこで生れたかとんと見当がつかぬ。\n');
    final Uint8List epub = await TextToEpub.convert(file: txt, title: 'Neko');
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, 'Neko.epub'), epub);
    _writeText(p.join(book, 'neko.srt'), srtV2);
    _write(p.join(book, '01.mp3'));
    _write(p.join(book, '02.mp3'));

    expect((await scan()).audiobooksAdded, 1);
    final String bookKey = (await db.getAllAudiobooks()).single.bookKey;
    expect(
      placement(await AudiobookRepository(db).cuesForBook(bookKey)),
      <(int, int)>[(0, 0), (1, 0), (1, 2000)],
    );
    final int importedAt = (await SrtBookRepository(
      db,
    ).findByBookKey(bookKey))!.importedAt;

    _write(p.join(book, '03.mp3'));
    final ScanSummary added = await scan();
    expect(added.errors, isEmpty);
    expect(added.audiobooksUpdated, 1);
    expect(
      placement(await AudiobookRepository(db).cuesForBook(bookKey)),
      <(int, int)>[(0, 0), (1, 0), (2, 0)],
      reason: '只换音频也要按新文件清单重新分配（同一份持久字幕重新对齐）',
    );
    expect(
      (await SrtBookRepository(db).findByBookKey(bookKey))!.importedAt,
      importedAt,
      reason: '重新对齐不是新导入',
    );
    expect(await persistedSubtitles(bookKey), hasLength(1));
  });

  test('探不出时长（未装配 / 坏文件）时 cue 留在第 0 个文件，不猜', () async {
    fakeDurations(<String, int>{'01.mp3': 2000});
    addTearDown(() => AudiobookStorage.audioDurationProbeMs = null);
    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, '01.mp3'));
    _write(p.join(book, '02.mp3'));
    _writeText(p.join(book, 'neko.srt'), srtV2);

    expect((await scan()).audiobooksAdded, 1);
    final SrtBook imported = await standalone('Neko');
    expect(
      placement(await SrtBookRepository(db).cuesFor(imported.uid)),
      <(int, int)>[(0, 0), (0, 2000), (0, 4000)],
    );
  });

  // ── 互联清单的内容版本（contentRevision）────────────────────────────────

  test('清单的 contentRevision：没变的重扫不变；补分段、换字幕各变一次', () async {
    final LocalLibraryHostService host = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory(p.join(tmp.path, 'dicts'))
        ..createSync(),
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    Future<String?> revision() async {
      final List<RemoteAudiobookInfo> list = await host.listAudiobooks();
      expect(list, hasLength(1));
      final String? rev = list.single.contentRevision;
      expect(
        await host.audiobookContentRevision(list.single.identity),
        rev,
        reason: '包端点给导出缓存定版本用的值必须与清单同源',
      );
      // 下载端从包 manifest 读版本记下来（不信可能过期的清单缓存）：包里的值必须
      // 与此刻清单里的值相同。
      final File package = await host.exportAudiobook(list.single.identity);
      addTearDown(() => package.parent.deleteSync(recursive: true));
      expect(
        await SyncAssetPackageService.readAudioPackageContentRevision(package),
        rev,
        reason: '包 manifest 的 contentRevision 必须与清单同源',
      );
      return rev;
    }

    final String book = p.join(root.path, 'Neko');
    _write(p.join(book, '01.mp3'));
    _writeText(p.join(book, 'neko.srt'), _kSrt);
    await scan();
    final String? r1 = await revision();
    expect(r1, isNotNull);
    expect(r1, startsWith('r1-'));

    expect((await scan()).audiobooksUpdated, 0);
    expect(await revision(), r1, reason: '没变的重扫不写库，版本不变');

    _write(p.join(book, '02.mp3'));
    expect((await scan()).audiobooksUpdated, 1);
    final String? r2 = await revision();
    expect(r2, isNot(r1));

    // 换字幕：持久副本可能与旧副本同名，版本靠大小 / 修改时刻区分。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _writeText(p.join(book, 'neko.srt'), srtV2);
    expect((await scan()).audiobooksUpdated, 1);
    final String? r3 = await revision();
    expect(r3, isNot(r2));
    expect(r3, isNot(r1));

    expect((await scan()).audiobooksUpdated, 0);
    expect(await revision(), r3);
  });
}
