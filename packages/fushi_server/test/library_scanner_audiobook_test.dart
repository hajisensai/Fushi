import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
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
}
