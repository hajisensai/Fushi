import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

class _ScriptedService implements MangaOcrService {
  final StreamController<MangaOcrDownloadEvent> events =
      StreamController<MangaOcrDownloadEvent>();
  int downloadCalls = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() {
    downloadCalls++;
    return events.stream;
  }

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: false,
    recognizerReady: false,
    diskBytes: 0,
    totalBytes: 100,
    obtainedBytes: 0,
  );

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

void main() {
  test(
    'progress sums per-file bytes instead of the latest event only',
    () async {
      final MangaOcrModelDownloads downloads = MangaOcrModelDownloads();
      addTearDown(downloads.dispose);
      final _ScriptedService service = _ScriptedService();
      expect(downloads.start(MangaOcrLocalModel.baberu, service), isTrue);
      service.events
        ..add(
          const MangaOcrDownloadEvent(
            fileName: 'a.onnx',
            receivedBytes: 10,
            totalBytes: 50,
          ),
        )
        ..add(
          const MangaOcrDownloadEvent(
            fileName: 'a.onnx',
            receivedBytes: 30,
            totalBytes: 50,
          ),
        )
        ..add(
          const MangaOcrDownloadEvent(
            fileName: 'b.onnx',
            receivedBytes: 5,
            totalBytes: 50,
          ),
        );
      await pumpEventQueue();
      final MangaOcrModelDownloadProgress? progress = downloads.progressOf(
        MangaOcrLocalModel.baberu,
      );
      expect(progress?.receivedBytes, 35);
      expect(progress?.currentFile, 'b.onnx');
    },
  );

  test('a model already downloading is not started twice', () async {
    final MangaOcrModelDownloads downloads = MangaOcrModelDownloads();
    addTearDown(downloads.dispose);
    final _ScriptedService service = _ScriptedService();
    expect(downloads.start(MangaOcrLocalModel.baberu, service), isTrue);
    expect(downloads.start(MangaOcrLocalModel.baberu, service), isFalse);
    expect(service.downloadCalls, 1);
    // 不同模型各占一槽，可以并行。
    expect(
      downloads.start(MangaOcrLocalModel.mangaCtc, _ScriptedService()),
      isTrue,
    );
  });

  test('completion and failure are reported; cancellation is not', () async {
    final List<(MangaOcrLocalModel, bool)> finished =
        <(MangaOcrLocalModel, bool)>[];
    final MangaOcrModelDownloads downloads = MangaOcrModelDownloads(
      onFinished: (MangaOcrLocalModel model, {required bool failed}) =>
          finished.add((model, failed)),
    );
    addTearDown(downloads.dispose);

    final _ScriptedService ok = _ScriptedService();
    downloads.start(MangaOcrLocalModel.baberu, ok);
    await ok.events.close();
    await pumpEventQueue();
    expect(downloads.isActive(MangaOcrLocalModel.baberu), isFalse);

    final _ScriptedService bad = _ScriptedService();
    downloads.start(MangaOcrLocalModel.mangaCtc, bad);
    bad.events.addError(StateError('network'));
    await pumpEventQueue();
    expect(downloads.isActive(MangaOcrLocalModel.mangaCtc), isFalse);

    final _ScriptedService cancelled = _ScriptedService();
    downloads.start(MangaOcrLocalModel.baberu, cancelled);
    await downloads.cancel(MangaOcrLocalModel.baberu);
    expect(downloads.isActive(MangaOcrLocalModel.baberu), isFalse);
    expect(cancelled.events.hasListener, isFalse);

    expect(finished, <(MangaOcrLocalModel, bool)>[
      (MangaOcrLocalModel.baberu, false),
      (MangaOcrLocalModel.mangaCtc, true),
    ]);
  });

  test('cancel keeps the slot until the downloader acknowledges', () async {
    final Completer<void> cleanup = Completer<void>();
    final StreamController<MangaOcrDownloadEvent> events =
        StreamController<MangaOcrDownloadEvent>(onCancel: () => cleanup.future);
    final MangaOcrModelDownloads downloads = MangaOcrModelDownloads();
    addTearDown(downloads.dispose);
    downloads.start(
      MangaOcrLocalModel.baberu,
      _FixedStreamService(events.stream),
    );
    final Future<void> cancelling = downloads.cancel(MangaOcrLocalModel.baberu);
    await pumpEventQueue();
    // 收尾前文件仍归下载器：槽位还在，删除 / 导入入口据此保持禁用。
    expect(downloads.isActive(MangaOcrLocalModel.baberu), isTrue);
    expect(downloads.progressOf(MangaOcrLocalModel.baberu)?.cancelling, isTrue);
    cleanup.complete();
    await cancelling;
    expect(downloads.isActive(MangaOcrLocalModel.baberu), isFalse);
  });
}

class _FixedStreamService extends _ScriptedService {
  _FixedStreamService(this.stream);

  final Stream<MangaOcrDownloadEvent> stream;

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => stream;
}
