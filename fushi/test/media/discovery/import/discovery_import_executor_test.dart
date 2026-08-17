import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

DiscoveryDomainImporters _recordingImporters(List<String> log) {
  return DiscoveryDomainImporters(
    importEpub: (String path) async {
      log.add('epub:$path');
      return 'key-epub';
    },
    importText: (String path) async {
      log.add('text:$path');
      return 'key-text';
    },
    importPdf: (String path) async {
      log.add('pdf:$path');
      return 'key-pdf';
    },
    importAudiobook: (AlignAudiobookPlan plan) async {
      log.add('audiobook:${plan.contentPath}+${plan.subtitlePath}'
          '+${plan.audioPaths.length}');
      return 'key-audiobook';
    },
    registerGameExes: (List<String> exePaths) async {
      log.add('game:${exePaths.join(',')}');
      return exePaths.length;
    },
  );
}

Future<File> _writeZip(
  Directory dir,
  String name,
  Map<String, String> entries,
) async {
  final Archive archive = Archive();
  entries.forEach((String path, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  final File out = File('${dir.path}${Platform.pathSeparator}$name');
  await out.writeAsBytes(ZipEncoder().encode(archive)!);
  return out;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('discovery_import_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('单文件 epub 直接走 epub 导入', () async {
    final List<String> log = <String>[];
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(log),
    );
    final File epub = File('${tempDir.path}${Platform.pathSeparator}a.epub');
    await epub.writeAsString('x');

    final DiscoveryImportOutcome outcome =
        await executor.importFile(DiscoveryMediaKind.novel, epub);
    expect(outcome.importedCount, 1);
    expect(outcome.summary, 'key-epub');
    expect(log.single, 'epub:${epub.path}');
  });

  test('zip 小说包:内置解码解压(带目录)后逐本导入', () async {
    final List<String> log = <String>[];
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(log),
      // 强制走内置 zip 解码路径(不依赖本机 7-Zip)。
      extractor: DiscoveryArchiveExtractor(sevenZipOverride: ''),
    );
    final File zip = await _writeZip(tempDir, 'books.zip', <String, String>{
      'vol1/a.epub': 'a',
      'vol1/b.txt': 'b',
      'cover.jpg': 'ignored',
    });

    final DiscoveryImportOutcome outcome =
        await executor.importFile(DiscoveryMediaKind.novel, zip);
    expect(outcome.importedCount, 2);
    expect(log, hasLength(2));
    expect(log[0], startsWith('epub:'));
    expect(log[1], startsWith('text:'));
    // 解出的文件真实落盘在压缩包旁的同名目录。
    expect(
      File('${tempDir.path}${Platform.pathSeparator}books'
              '${Platform.pathSeparator}vol1${Platform.pathSeparator}a.epub')
          .existsSync(),
      isTrue,
    );
  });

  test('zip 有声书包:齐料 → 对齐导入', () async {
    final List<String> log = <String>[];
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(log),
      extractor: DiscoveryArchiveExtractor(sevenZipOverride: ''),
    );
    final File zip = await _writeZip(tempDir, 'ab.zip', <String, String>{
      'book.epub': 'e',
      'book.srt': 's',
      '01.mp3': 'm',
      '02.mp3': 'm',
    });

    final DiscoveryImportOutcome outcome =
        await executor.importFile(DiscoveryMediaKind.audiobook, zip);
    expect(outcome.importedCount, 1);
    expect(log.single, contains('audiobook:'));
    expect(log.single, contains('+2'));
  });

  test('zip 游戏包:挑主 exe 登记', () async {
    final List<String> log = <String>[];
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(log),
      extractor: DiscoveryArchiveExtractor(sevenZipOverride: ''),
    );
    final File zip = await _writeZip(tempDir, 'game.zip', <String, String>{
      'game/atri.exe': 'gamegamegame',
      'game/unins000.exe': 'u',
      'game/data.xp3': 'd',
    });

    final DiscoveryImportOutcome outcome =
        await executor.importFile(DiscoveryMediaKind.game, zip);
    expect(outcome.importedCount, 1);
    expect(log.single, startsWith('game:'));
    expect(log.single, contains('atri.exe'));
    expect(log.single, isNot(contains('unins')));
  });

  test('缺 7-Zip 时 7z 包给稳定原因码', () async {
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(<String>[]),
      extractor: DiscoveryArchiveExtractor(sevenZipOverride: ''),
    );
    final File archive = File('${tempDir.path}${Platform.pathSeparator}x.7z');
    await archive.writeAsBytes(<int>[0x37, 0x7a]);

    expect(
      () => executor.importFile(DiscoveryMediaKind.game, archive),
      throwsA(
        isA<DiscoveryImportBlockedException>().having(
          (DiscoveryImportBlockedException e) => e.blocker,
          'blocker',
          DiscoveryImportBlocker.archiveToolMissing,
        ),
      ),
    );
  });

  test('注入 7za runner:命令形状正确,非零退出按解压失败', () async {
    final List<List<String>> calls = <List<String>>[];
    final DiscoveryArchiveExtractor extractor = DiscoveryArchiveExtractor(
      sevenZipOverride: '/fake/7za',
      runProcess: (String exe, List<String> args) async {
        calls.add(<String>[exe, ...args]);
        return ProcessResult(0, 2, '', 'wrong password');
      },
    );
    final File archive = File('${tempDir.path}${Platform.pathSeparator}p.rar');
    await archive.writeAsBytes(<int>[0x52, 0x61, 0x72]);

    await expectLater(
      extractor.extract(archive.path, intoDir: '${tempDir.path}/out'),
      throwsA(
        isA<DiscoveryImportBlockedException>().having(
          (DiscoveryImportBlockedException e) => e.blocker,
          'blocker',
          DiscoveryImportBlocker.archiveExtractionFailed,
        ),
      ),
    );
    expect(calls.single.first, '/fake/7za');
    expect(calls.single, contains('x'));
    expect(calls.single, contains(archive.path));
  });

  test('恶意 zip(条目带 ..)被拒', () async {
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(<String>[]),
      extractor: DiscoveryArchiveExtractor(sevenZipOverride: ''),
    );
    final File zip = await _writeZip(tempDir, 'evil.zip', <String, String>{
      '../evil.txt': 'x',
    });

    expect(
      () => executor.importFile(DiscoveryMediaKind.novel, zip),
      throwsA(isA<DiscoveryImportBlockedException>()),
    );
  });

  test('域认不出的下载物按 unknownFileType 挡下', () async {
    final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
      importers: _recordingImporters(<String>[]),
    );
    final File file = File('${tempDir.path}${Platform.pathSeparator}x.bin');
    await file.writeAsString('x');

    expect(
      () => executor.importFile(DiscoveryMediaKind.novel, file),
      throwsA(
        isA<DiscoveryImportBlockedException>().having(
          (DiscoveryImportBlockedException e) => e.blocker,
          'blocker',
          DiscoveryImportBlocker.unknownFileType,
        ),
      ),
    );
  });
}
