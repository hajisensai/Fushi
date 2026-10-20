import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// BUG-3605：远程（已配对主机）整卷 OCR 先把页图逐张上传、再由 host 逐页识别，
/// 两段各自从 0 数到总页数。转成统一后台事件时若丢掉阶段，阅读器右上角的
/// 「OCR x/y」就会走完一遍又从 0 再走一遍。这里钉死：
/// 1. 上传段事件带 `uploading: true`，识别段为 false；
/// 2. finished 事件的总页数取前面进度报过的值（远程 finished 本身不带页数）。

class _NoopService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: false,
    recognizerReady: false,
    diskBytes: 0,
    totalBytes: 1,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

class _ScriptedRemoteRunner implements MangaOcrRemoteRunner {
  _ScriptedRemoteRunner(this.events);

  final List<MangaOcrRemoteEvent> events;

  @override
  Future<MangaOcrRemoteTarget?> probe() async => null;

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) => Stream<MangaOcrRemoteEvent>.fromIterable(events);
}

void main() {
  test('远程引擎：上传段标 uploading，识别段不标，finished 带总页数', () async {
    final MangaOcrJobSpec spec = MangaOcrJobSpec(
      engine: MangaOcrEngineId.pairedHost,
      engines: MangaOcrWizardEngines(
        service: _NoopService(),
        remoteRunner: _ScriptedRemoteRunner(const <MangaOcrRemoteEvent>[
          MangaOcrRemoteEvent.uploading(done: 1, total: 3),
          MangaOcrRemoteEvent.uploading(done: 2, total: 3),
          MangaOcrRemoteEvent.uploading(done: 3, total: 3),
          MangaOcrRemoteEvent.running(done: 0, total: 3),
          MangaOcrRemoteEvent.running(done: 2, total: 3),
          MangaOcrRemoteEvent.finished(mangaJsonPath: '/tmp/manga.json'),
        ]),
      ),
      imageDirPath: '/tmp/vol',
      lensLanguage: 'ja',
      remoteTarget: const MangaOcrRemoteTarget(
        baseUrl: 'https://host:38765',
        capability: MangaOcrRemoteCapability(
          supported: true,
          modelsReady: true,
        ),
      ),
    );

    final List<MangaOcrBackgroundEvent> out = await mangaOcrBackgroundEvents(
      spec,
    ).toList();

    expect(
      out
          .where((MangaOcrBackgroundEvent e) => !e.finished)
          .map(
            (MangaOcrBackgroundEvent e) =>
                '${e.uploading ? 'up' : 'ocr'} ${e.pagesDone}/${e.pagesTotal}',
          )
          .toList(),
      <String>['up 1/3', 'up 2/3', 'up 3/3', 'ocr 0/3', 'ocr 2/3'],
      reason: '上传与识别两段必须可区分，否则同一条进度会走两遍',
    );
    final MangaOcrBackgroundEvent finished = out.last;
    expect(finished.finished, isTrue);
    expect(finished.uploading, isFalse);
    expect(finished.pagesTotal, 3, reason: '远程 finished 不带页数，须沿用进度报过的总页数');
    expect(finished.pagesDone, 3);
    expect(finished.resultPath, '/tmp/manga.json');
  });
}
