import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_model_downloads.dart';

/// 下载流由测试手动推：验证登记表的进度累计、失败原因、取消与去重。
class _FakeService extends AsrTranscriptionService {
  _FakeService(Directory root)
    : super(
        audioProfile: AsrAudioProfile.cleanSpeech,
        backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
        openStore: (AsrLanguage l) async => AsrModelStore(
          Directory(p.join(root.path, asrModelPackFor(l).id)),
          asrModelPackFor(l),
        ),
        jobsRoot: () async => root,
      );

  StreamController<ModelDownloadEvent>? controller;

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) {
    controller = StreamController<ModelDownloadEvent>();
    return controller!.stream;
  }
}

OnnxSessionFactory _unusedOnnxFactory() =>
    throw UnimplementedError('本用例不该建 ONNX 后端');

AsrTranscribePlan _plan({int obtained = 0}) => AsrTranscribePlan(
  language: AsrLanguage.japanese,
  variant: AsrEncoderVariant.int8,
  expectedProvider: OnnxExecutionProvider.cpu,
  modelStatus: AsrModelStatus(
    ready: false,
    diskBytes: obtained,
    totalBytes: 300,
    obtainedBytes: obtained,
  ),
);

void main() {
  late Directory tmp;
  late _FakeService service;
  final AsrModelPack pack = asrModelPackFor(AsrLanguage.japanese);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_model_downloads_test_');
    service = _FakeService(tmp);
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('逐文件事件累计成整包进度；同一个包不重复发起；结束后释放槽位', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = AsrModelDownloads(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    expect(downloads.start(pack, service: service, plan: _plan()), isTrue);
    expect(downloads.isActive(pack.id), isTrue);
    expect(downloads.start(pack, service: service, plan: _plan()), isFalse);

    service.controller!
      ..add(
        const ModelDownloadEvent(
          fileName: 'a',
          receivedBytes: 100,
          totalBytes: 100,
        ),
      )
      ..add(
        const ModelDownloadEvent(
          fileName: 'b',
          receivedBytes: 50,
          totalBytes: 200,
        ),
      );
    await Future<void>.delayed(Duration.zero);
    final AsrModelDownloadProgress progress = downloads.progressOf(pack.id)!;
    expect(progress.receivedBytes, 150);
    expect(progress.totalBytes, 300);
    expect(progress.currentFile, 'b');

    await service.controller!.close();
    await Future<void>.delayed(Duration.zero);
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), isNull);
    expect(finished, <Object?>[null]);
  });

  test('失败原因进登记表（之后 CLI 查得到），重新下载时清掉', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = AsrModelDownloads(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    downloads.start(pack, service: service, plan: _plan());
    service.controller!.addError(const SocketException('boom'));
    await Future<void>.delayed(Duration.zero);
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), contains('boom'));
    expect(finished.single, isA<SocketException>());

    downloads.start(pack, service: service, plan: _plan());
    expect(downloads.lastErrorOf(pack.id), isNull);
  });

  test('取消：槽位释放、不记失败、不回调结束', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = AsrModelDownloads(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    downloads.start(pack, service: service, plan: _plan(obtained: 40));
    expect(downloads.progressOf(pack.id)!.receivedBytes, 40);
    await downloads.cancel(pack.id);
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), isNull);
    expect(finished, isEmpty);
  });
}
