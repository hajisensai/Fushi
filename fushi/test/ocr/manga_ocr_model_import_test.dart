import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/manga_ocr_model_import.dart';
import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:path/path.dart' as p;

/// 手动导入的判据只有两条：basename 命中清单 + 字节数等于预期。这组测试盯着
/// 这两条以及「落盘必须原子」的后果——半个模型转正后只会在推理时炸成一堆看不懂
/// 的 ORT 错误，比当场拒绝糟糕得多。
void main() {
  late Directory tempDir;
  late Directory sourceDir;
  late Directory targetDir;

  const List<MangaOcrModelFile> manifest = <MangaOcrModelFile>[
    MangaOcrModelFile(
      fileName: 'detector.onnx',
      url: 'https://example.invalid/detector.onnx',
      expectedBytes: 8,
      role: MangaOcrModelRole.detector,
    ),
    MangaOcrModelFile(
      fileName: 'vocab.txt',
      url: 'https://example.invalid/vocab.txt',
      expectedBytes: 4,
      role: MangaOcrModelRole.recognizer,
    ),
  ];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('manga_ocr_import_');
    sourceDir = Directory(p.join(tempDir.path, 'src'))..createSync();
    targetDir = Directory(p.join(tempDir.path, 'models'))..createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File writeSource(String name, int length) {
    final File file = File(p.join(sourceDir.path, name));
    file.writeAsBytesSync(List<int>.generate(length, (int i) => i % 251));
    return file;
  }

  MangaOcrModelImporter importer() =>
      MangaOcrModelImporter(manifest: manifest);

  test('逐个选文件：命中清单且长度正确的落盘转正，清单齐全后 allReady', () async {
    final File detector = writeSource('detector.onnx', 8);
    final File vocab = writeSource('vocab.txt', 4);

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[detector.path, vocab.path],
      targetDir: targetDir,
    );

    expect(result.imported, <String>['detector.onnx', 'vocab.txt']);
    expect(result.rejected, isEmpty);
    expect(result.allReady, isTrue);
    expect(result.changed, isTrue);
    expect(File(p.join(targetDir.path, 'detector.onnx')).lengthSync(), 8);
    expect(File(p.join(targetDir.path, 'vocab.txt')).lengthSync(), 4);
    expect(
      Directory(targetDir.path)
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.import'))
          .toList(),
      isEmpty,
      reason: '临时名必须在转正后消失，不能留半成品',
    );
  });

  test('长度不符：拒绝并回报期望/实际，绝不转正', () async {
    final File truncated = writeSource('detector.onnx', 5);

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[truncated.path],
      targetDir: targetDir,
    );

    expect(result.imported, isEmpty);
    expect(result.rejected.single.reason,
        MangaOcrModelImportRejectReason.sizeMismatch);
    expect(result.rejected.single.actualBytes, 5);
    expect(result.rejected.single.expectedBytes, 8);
    expect(File(p.join(targetDir.path, 'detector.onnx')).existsSync(), isFalse,
        reason: '被截断的档一旦转正，错误会推迟到推理时才爆');
    expect(result.stillMissing, containsAll(<String>['detector.onnx']));
  });

  test('不认识的文件：拒绝且不影响同批里认得的文件', () async {
    final File junk = writeSource('random.bin', 8);
    final File vocab = writeSource('vocab.txt', 4);

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[junk.path, vocab.path],
      targetDir: targetDir,
    );

    expect(result.imported, <String>['vocab.txt']);
    expect(result.rejected.single.reason,
        MangaOcrModelImportRejectReason.unknownFile);
    expect(result.matchedNothing, isFalse);
  });

  test('选文件夹：递归命中，无关文件不进拒绝列表（否则刷一屏噪音）', () async {
    final Directory nested = Directory(p.join(sourceDir.path, 'nested'))
      ..createSync();
    File(p.join(nested.path, 'detector.onnx'))
        .writeAsBytesSync(List<int>.filled(8, 1));
    File(p.join(nested.path, 'page_001.jpg'))
        .writeAsBytesSync(List<int>.filled(999, 2));

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[sourceDir.path],
      targetDir: targetDir,
    );

    expect(result.imported, <String>['detector.onnx']);
    expect(result.rejected, isEmpty,
        reason: '目录里的无关文件是常态，不该逐个报错');
  });

  test('zip 包：只解出清单命中的 entry，其余整包忽略', () async {
    final String zipPath = p.join(sourceDir.path, 'models.zip');
    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(zipPath);
    encoder.addArchiveFile(
        ArchiveFile('detector.onnx', 8, List<int>.filled(8, 7)));
    encoder.addArchiveFile(ArchiveFile('vocab.txt', 4, List<int>.filled(4, 9)));
    encoder.addArchiveFile(
        ArchiveFile('readme.txt', 3, List<int>.filled(3, 1)));
    encoder.closeSync();

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[zipPath],
      targetDir: targetDir,
    );

    expect(result.imported, containsAll(<String>['detector.onnx', 'vocab.txt']));
    expect(result.allReady, isTrue);
    expect(File(p.join(targetDir.path, 'detector.onnx')).lengthSync(), 8);
    expect(File(p.join(targetDir.path, 'readme.txt')).existsSync(), isFalse);
  });

  test('zip 里长度不符的 entry 被拒，同包里正确的仍然导入', () async {
    final String zipPath = p.join(sourceDir.path, 'models.zip');
    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(zipPath);
    encoder.addArchiveFile(
        ArchiveFile('detector.onnx', 3, List<int>.filled(3, 7)));
    encoder.addArchiveFile(ArchiveFile('vocab.txt', 4, List<int>.filled(4, 9)));
    encoder.closeSync();

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[zipPath],
      targetDir: targetDir,
    );

    expect(result.imported, <String>['vocab.txt']);
    expect(result.rejected.single.reason,
        MangaOcrModelImportRejectReason.sizeMismatch);
    expect(result.stillMissing, <String>['detector.onnx']);
  });

  test('已有好档：跳过不覆盖；已有坏档：被正确的档顶掉', () async {
    File(p.join(targetDir.path, 'vocab.txt'))
        .writeAsBytesSync(List<int>.filled(4, 0));
    // 坏档：存在但长度不符，宽松的「就绪」判定会放它过去，必须被覆盖。
    File(p.join(targetDir.path, 'detector.onnx'))
        .writeAsBytesSync(List<int>.filled(2, 0));

    writeSource('vocab.txt', 4);
    writeSource('detector.onnx', 8);

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[sourceDir.path],
      targetDir: targetDir,
    );

    expect(result.skipped, <String>['vocab.txt']);
    expect(result.imported, <String>['detector.onnx']);
    expect(File(p.join(targetDir.path, 'detector.onnx')).lengthSync(), 8,
        reason: '长度不符的坏档必须能被顶掉，否则用户永远导不进正确的文件');
  });

  test('导入成功要清掉同名 .part：那几百 MB 残留既没用也占磁盘', () async {
    File(p.join(targetDir.path, 'detector.onnx.part'))
        .writeAsBytesSync(List<int>.filled(3, 0));
    writeSource('detector.onnx', 8);

    await importer().import(
      sourcePaths: <String>[p.join(sourceDir.path, 'detector.onnx')],
      targetDir: targetDir,
    );

    expect(File(p.join(targetDir.path, 'detector.onnx.part')).existsSync(),
        isFalse);
  });

  test('什么都没认出来：matchedNothing 为真，让 UI 能单独提示选错了', () async {
    writeSource('random.bin', 8);

    final MangaOcrModelImportResult result = await importer().import(
      sourcePaths: <String>[p.join(sourceDir.path, 'random.bin')],
      targetDir: targetDir,
    );

    expect(result.matchedNothing, isTrue);
    expect(result.allReady, isFalse);
  });

  test('basename 匹配大小写不敏感', () {
    expect(matchMangaOcrModelFile('DETECTOR.ONNX', manifest)?.fileName,
        'detector.onnx');
    expect(matchMangaOcrModelFile('nope.onnx', manifest), isNull);
  });
}
