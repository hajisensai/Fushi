import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_selected_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

const MangaOcrModelStatus _mangaStatus = MangaOcrModelStatus(
  detectorReady: true,
  recognizerReady: true,
  diskBytes: 100,
  totalBytes: 100,
);
const MangaOcrModelStatus _baberuStatus = MangaOcrModelStatus(
  detectorReady: false,
  recognizerReady: false,
  diskBytes: 25,
  totalBytes: 70,
);

/// A controllable source whose cancellation waits for its resource teardown.
class _Source<T> {
  _Source() {
    controller = StreamController<T>(
      sync: true,
      onCancel: () {
        cancelled = true;
        return releaseCancellation.future;
      },
    );
  }

  late final StreamController<T> controller;
  final Completer<void> releaseCancellation = Completer<void>();
  bool cancelled = false;

  void release() {
    if (!releaseCancellation.isCompleted) releaseCancellation.complete();
  }

  void dispose() {
    release();
    unawaited(controller.close());
  }
}

class _FolderCall {
  _FolderCall(this.directory, this.title);

  final String directory;
  final String? title;
  final _Source<MangaOcrVolumeEvent> source = _Source<MangaOcrVolumeEvent>();
}

class _Service extends MangaOcrService {
  _Service({required this.supported, required this.status});

  final bool supported;
  final MangaOcrModelStatus status;
  int statusCalls = 0;
  int deleteCalls = 0;
  final List<_Source<MangaOcrDownloadEvent>> downloads =
      <_Source<MangaOcrDownloadEvent>>[];
  final List<_FolderCall> folders = <_FolderCall>[];

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async {
    statusCalls++;
    return status;
  }

  @override
  Future<int> deleteModels() async {
    deleteCalls++;
    return status.diskBytes;
  }

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() {
    final _Source<MangaOcrDownloadEvent> source =
        _Source<MangaOcrDownloadEvent>();
    downloads.add(source);
    return source.controller.stream;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) {
    final _FolderCall call = _FolderCall(imageDirPath, volumeTitle);
    folders.add(call);
    return call.source.controller.stream;
  }

  void dispose() {
    for (final _Source<MangaOcrDownloadEvent> source in downloads) {
      source.dispose();
    }
    for (final _FolderCall call in folders) {
      call.source.dispose();
    }
  }
}

class _PreparedService extends _Service
    implements MangaOcrModelPreparationService {
  _PreparedService() : super(supported: true, status: _mangaStatus);
  final StreamController<MangaOcrDownloadEvent> preparation =
      StreamController<MangaOcrDownloadEvent>();

  @override
  Stream<MangaOcrDownloadEvent> prepareModels() => preparation.stream;
}

void main() {
  test(
    'preparation captures the selected engine before preference changes',
    () async {
      final _PreparedService first = _PreparedService();
      final _PreparedService second = _PreparedService();
      MangaOcrService current = first;
      final SelectedMangaOcrService selected = SelectedMangaOcrService(
        () => current,
      );
      final Stream<MangaOcrDownloadEvent> operation = selected.prepareModels();
      current = second;
      final Future<List<MangaOcrDownloadEvent>> results = operation.toList();
      const MangaOcrDownloadEvent event = MangaOcrDownloadEvent(
        fileName: 'runtime',
        receivedBytes: 0,
        totalBytes: 0,
        installing: true,
      );
      first.preparation.add(event);
      await first.preparation.close();
      expect(await results, <MangaOcrDownloadEvent>[event]);
      final Future<void> unusedClosed = second.preparation.close();
      await second.preparation.stream.drain<void>();
      await unusedClosed;
    },
  );

  late _Service manga;
  late _Service baberu;
  late MangaOcrService selected;
  late SelectedMangaOcrService service;

  setUp(() {
    manga = _Service(supported: true, status: _mangaStatus);
    baberu = _Service(supported: false, status: _baberuStatus);
    selected = manga;
    service = SelectedMangaOcrService(() => selected);
  });

  tearDown(() {
    manga.dispose();
    baberu.dispose();
  });

  test(
      'new status and deletion use the current model, pending work keeps its model',
      () async {
    expect(service.isSupportedPlatform, isTrue);
    final Future<MangaOcrModelStatus> previousStatus = service.modelStatus();
    final Future<int> previousDelete = service.deleteModels();

    selected = baberu;
    expect(service.isSupportedPlatform, isFalse);
    expect(await previousStatus, same(_mangaStatus));
    expect(await previousDelete, 100);
    expect(await service.modelStatus(), same(_baberuStatus));
    expect(await service.deleteModels(), 25);
    expect(manga.statusCalls, 1);
    expect(manga.deleteCalls, 1);
    expect(baberu.statusCalls, 1);
    expect(baberu.deleteCalls, 1);

    selected = manga;
    expect(await service.modelStatus(), same(_mangaStatus));
    expect(manga.statusCalls, 2);
  });

  test(
      'download selected before listening stays with that model and forwards cancel',
      () async {
    final Stream<MangaOcrDownloadEvent> previous = service.downloadModels();
    selected = baberu;
    final Stream<MangaOcrDownloadEvent> current = service.downloadModels();
    final List<MangaOcrDownloadEvent> previousEvents =
        <MangaOcrDownloadEvent>[];
    final List<MangaOcrDownloadEvent> currentEvents = <MangaOcrDownloadEvent>[];
    final StreamSubscription<MangaOcrDownloadEvent> previousSub =
        previous.listen(previousEvents.add);
    final StreamSubscription<MangaOcrDownloadEvent> currentSub =
        current.listen(currentEvents.add);
    const MangaOcrDownloadEvent oldProgress = MangaOcrDownloadEvent(
      fileName: 'encoder_model.onnx',
      receivedBytes: 40,
      totalBytes: 100,
    );
    const MangaOcrDownloadEvent newProgress = MangaOcrDownloadEvent(
      fileName: 'vision_fp16.onnx',
      receivedBytes: 10,
      totalBytes: 70,
    );
    manga.downloads.single.controller.add(oldProgress);
    baberu.downloads.single.controller.add(newProgress);
    expect(previousEvents, <MangaOcrDownloadEvent>[oldProgress]);
    expect(currentEvents, <MangaOcrDownloadEvent>[newProgress]);

    bool cancelled = false;
    final Future<void> cancellation = previousSub.cancel().then<void>((_) {
      cancelled = true;
    });
    await Future<void>.value();
    expect(manga.downloads.single.cancelled, isTrue);
    expect(baberu.downloads.single.cancelled, isFalse);
    expect(cancelled, isFalse,
        reason: 'cancel must await the old download teardown');
    manga.downloads.single.release();
    await cancellation;
    expect(cancelled, isTrue);

    selected = manga;
    baberu.downloads.single.release();
    await currentSub.cancel();
    expect(baberu.downloads.single.cancelled, isTrue);
  });

  test(
      'active OCR retains model and arguments; new OCR selects anew and errors pass through',
      () async {
    final Stream<MangaOcrVolumeEvent> previous = service.ocrFolder(
      imageDirPath: 'D:/books/previous',
      volumeTitle: 'Previous volume',
    );
    final List<MangaOcrVolumeEvent> previousEvents = <MangaOcrVolumeEvent>[];
    final List<Object> errors = <Object>[];
    selected = baberu;
    final StreamSubscription<MangaOcrVolumeEvent> previousSub = previous.listen(
      previousEvents.add,
      onError: (Object error, StackTrace stack) => errors.add(error),
    );
    final List<MangaOcrVolumeEvent> currentEvents = <MangaOcrVolumeEvent>[];
    final StreamSubscription<MangaOcrVolumeEvent> currentSub = service
        .ocrFolder(imageDirPath: 'D:/books/current')
        .listen(currentEvents.add);
    expect(manga.folders.single.directory, 'D:/books/previous');
    expect(manga.folders.single.title, 'Previous volume');
    expect(baberu.folders.single.directory, 'D:/books/current');
    expect(baberu.folders.single.title, isNull);

    const MangaOcrVolumeEvent progress = MangaOcrVolumeEvent.page(
      pagesDone: 1,
      pagesTotal: 2,
    );
    const MangaOcrVolumeEvent finished = MangaOcrVolumeEvent.finished(
      pagesTotal: 4,
      mangaJsonPath: 'D:/books/current/manga.json',
    );
    final StateError failure = StateError('old model failed on page two');
    manga.folders.single.source.controller.add(progress);
    manga.folders.single.source.controller
        .addError(failure, StackTrace.current);
    baberu.folders.single.source.controller.add(finished);
    expect(previousEvents, <MangaOcrVolumeEvent>[progress]);
    expect(currentEvents, <MangaOcrVolumeEvent>[finished]);
    expect(errors.single, same(failure));

    bool cancelled = false;
    final Future<void> cancellation = previousSub.cancel().then<void>((_) {
      cancelled = true;
    });
    await Future<void>.value();
    expect(manga.folders.single.source.cancelled, isTrue);
    expect(baberu.folders.single.source.cancelled, isFalse);
    expect(cancelled, isFalse,
        reason: 'cancel must await the old OCR teardown');
    manga.folders.single.source.release();
    await cancellation;

    selected = manga;
    baberu.folders.single.source.release();
    await currentSub.cancel();
    expect(baberu.folders.single.source.cancelled, isTrue);
  });
}
