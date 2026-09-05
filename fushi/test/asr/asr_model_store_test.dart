import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:path/path.dart' as p;

/// 记录调用并把缺失文件写成 3 字节小文件的 fake 下载器。
///
/// 真实字节数是 592 MB 级，本地 HttpServer 喂不出；共享下载器自己的续传 /
/// 镜像 / 长度校验已由 `test/ocr/manga_ocr_model_downloader_test.dart` 覆盖，
/// 这里只验 store 把「哪些文件、放哪、怎么判就绪」交对了。
class _RecordingDownloader extends ModelFileDownloader {
  _RecordingDownloader();

  static const int _writeBytes = 3;
  List<DownloadableModelFile>? files;
  Directory? targetDir;
  bool Function(File file)? isReady;

  @override
  Stream<ModelDownloadEvent> downloadAll({
    required List<DownloadableModelFile> files,
    required Directory targetDir,
    required bool Function(File file) isReady,
  }) async* {
    this.files = files;
    this.targetDir = targetDir;
    this.isReady = isReady;
    await targetDir.create(recursive: true);
    for (final DownloadableModelFile file in files) {
      final File target = File(p.join(targetDir.path, file.fileName));
      if (!isReady(target)) {
        target.writeAsBytesSync(List<int>.filled(_writeBytes, 7));
      }
      yield ModelDownloadEvent(
        fileName: file.fileName,
        receivedBytes: target.lengthSync(),
        totalBytes: target.lengthSync(),
      );
    }
    yield ModelDownloadEvent(
      fileName: files.last.fileName,
      receivedBytes: files.last.expectedBytes,
      totalBytes: files.last.expectedBytes,
      done: true,
    );
  }
}

void main() {
  late Directory tempDir;
  late AsrModelStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('asr_store_');
    store = AsrModelStore(Directory(p.join(tempDir.path, 'models')));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void writeReady(AsrModelRole role, [int bytes = 4]) {
    final File file = store.fileFor(role);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 1));
  }

  test('fileFor 按清单文件名落在模型目录下', () {
    expect(
      store.fileFor(AsrModelRole.encoderInt8).path,
      p.join(store.dir.path, 'encoder-epoch-99-avg-1.int8.onnx'),
    );
    expect(
      store.fileFor(AsrModelRole.tokens).path,
      p.join(store.dir.path, 'tokens.txt'),
    );
  });

  test('空目录：两个变体都未就绪，状态全零', () async {
    expect(store.isReady(AsrEncoderVariant.int8), isFalse);
    expect(store.isReady(AsrEncoderVariant.fp32), isFalse);
    final AsrModelStatus status = await store.status(AsrEncoderVariant.int8);
    expect(status.ready, isFalse);
    expect(status.diskBytes, 0);
    expect(status.obtainedBytes, 0);
    expect(status.totalBytes, asrModelTotalBytes(AsrEncoderVariant.int8));
    expect(status.hasAnyFiles, isFalse);
  });

  test('就绪按变体独立：只下了 int8 编码器时 fp32 仍未就绪', () async {
    for (final AsrModelRole role in <AsrModelRole>[
      AsrModelRole.encoderInt8,
      AsrModelRole.decoder,
      AsrModelRole.joiner,
      AsrModelRole.tokens,
      AsrModelRole.vad,
    ]) {
      writeReady(role);
    }
    expect(store.isReady(AsrEncoderVariant.int8), isTrue);
    expect(store.isReady(AsrEncoderVariant.fp32), isFalse);
    expect((await store.status(AsrEncoderVariant.fp32)).ready, isFalse);
    expect((await store.status(AsrEncoderVariant.int8)).ready, isTrue);
  });

  test('空文件不算就绪', () {
    for (final AsrModelFile f in asrModelFilesFor(AsrEncoderVariant.int8)) {
      writeReady(f.role);
    }
    store.fileFor(AsrModelRole.vad).writeAsBytesSync(<int>[]);
    expect(store.isReady(AsrEncoderVariant.int8), isFalse);
  });

  test('status：obtainedBytes 含 .part，diskBytes 是目录真实占用（含另一变体）', () async {
    writeReady(AsrModelRole.decoder, 10);
    writeReady(AsrModelRole.tokens, 5);
    // 另一个变体的编码器：占磁盘，但不算进 int8 的 obtained。
    writeReady(AsrModelRole.encoderFp32, 100);
    // int8 编码器下了一半。
    File(
      '${store.fileFor(AsrModelRole.encoderInt8).path}.part',
    ).writeAsBytesSync(List<int>.filled(7, 2));

    final AsrModelStatus status = await store.status(AsrEncoderVariant.int8);
    expect(status.ready, isFalse);
    expect(
      status.obtainedBytes,
      10 + 5 + 7,
      reason: '.part 里攒下的字节下次会被 Range 续上，必须算进「已下多少」',
    );
    expect(
      status.diskBytes,
      10 + 5 + 100 + 7,
      reason: '占用按目录真实大小记账，删除时才对得上（BUG-1732）',
    );
    expect(status.hasAnyFiles, isTrue);
  });

  test('download：把该变体的清单、目录与就绪判定交给下载器，事件原样透传', () async {
    writeReady(AsrModelRole.tokens);
    final _RecordingDownloader downloader = _RecordingDownloader();

    final List<ModelDownloadEvent> events = await store
        .download(AsrEncoderVariant.int8, downloader: downloader)
        .toList();

    expect(downloader.files, asrModelFilesFor(AsrEncoderVariant.int8));
    expect(downloader.targetDir!.path, store.dir.path);
    // 就绪判定就是清单里那条规则（存在且非空）。
    expect(downloader.isReady!(store.fileFor(AsrModelRole.tokens)), isTrue);
    expect(downloader.isReady!(File(p.join(store.dir.path, 'nope'))), isFalse);
    final File empty = File(p.join(store.dir.path, 'empty'))
      ..writeAsBytesSync(<int>[]);
    expect(downloader.isReady!(empty), isFalse);
    expect(events.last.done, isTrue);
    expect(events.where((ModelDownloadEvent e) => e.done), hasLength(1));
    expect(store.isReady(AsrEncoderVariant.int8), isTrue);
    expect(store.isReady(AsrEncoderVariant.fp32), isFalse, reason: '只下了请求的变体');
  });

  test('download 默认下载器用 ASR 候选序列（主源→hf-mirror→第二源）', () {
    // 不真的发请求：只验证默认构造不抛，且候选派生走清单函数。
    expect(store.download(AsrEncoderVariant.int8), isA<Stream<Object?>>());
    expect(
      asrModelUrlCandidates(kAsrTokensFile).length,
      4,
      reason: 'tokens 有第二源：2 个源 × (主 + hf-mirror)',
    );
  });

  test('deleteAll：返回释放字节数并删掉整个目录；目录不存在返回 0', () async {
    expect(await store.deleteAll(), 0);
    writeReady(AsrModelRole.decoder, 10);
    File(
      '${store.fileFor(AsrModelRole.encoderInt8).path}.part',
    ).writeAsBytesSync(List<int>.filled(6, 2));

    expect(await store.deleteAll(), 16, reason: '先量后删，.part 一并算');
    expect(store.dir.existsSync(), isFalse);
    expect(await store.deleteAll(), 0);
  });
}
