import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/shared_model_downloads.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrAudioProfile,
        AsrEncoderVariant,
        AsrLanguage,
        ModelDownloadEvent,
        asrModelPackFor;

/// kZZmXQBv7E：模型下载以前挂在弹层上，关掉再开、再点一次就起第二条写者，两条流
/// 同时往同一个 `.part` 里 append，之后每次 Range 续传都是 HTTP 416。
void main() {
  ModelDownloadEvent ev(int received) => ModelDownloadEvent(
    fileName: 'model.onnx_data',
    receivedBytes: received,
    totalBytes: 100,
  );

  test('已在下载时再 join 不另起写者，只挂上去', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>();
    int starts = 0;
    Stream<ModelDownloadEvent> start() {
      starts++;
      return source.stream;
    }

    final List<int> first = <int>[];
    final StreamSubscription<ModelDownloadEvent> a = shared
        .join('asr:p', start)
        .listen((ModelDownloadEvent e) => first.add(e.receivedBytes));
    source.add(ev(10));
    await pumpEventQueue();

    final List<int> second = <int>[];
    final Completer<void> secondDone = Completer<void>();
    shared
        .join('asr:p', start)
        .listen(
          (ModelDownloadEvent e) => second.add(e.receivedBytes),
          onDone: secondDone.complete,
        );
    await pumpEventQueue();
    expect(starts, 1, reason: '同一个键同一时刻只能有一条写者');
    expect(second, <int>[10], reason: '后挂上的先补最近一条进度');

    source.add(ev(20));
    await source.close();
    await secondDone.future;
    expect(first, <int>[10, 20]);
    expect(second, <int>[10, 20]);
    expect(shared.isActive('asr:p'), isFalse);
    await a.cancel();
  });

  test('监听方取消（关弹层）不停下载；attach 接回进行中的那条', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    bool sourceCancelled = false;
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>(
          onCancel: () => sourceCancelled = true,
        );

    final StreamSubscription<ModelDownloadEvent> sheet = shared
        .join('moss', () => source.stream)
        .listen((_) {});
    source.add(ev(30));
    await pumpEventQueue();
    await sheet.cancel();
    expect(sourceCancelled, isFalse);
    expect(shared.isActive('moss'), isTrue);
    expect(shared.latestOf('moss')?.receivedBytes, 30);

    final Stream<ModelDownloadEvent>? resumed = shared.attach('moss');
    expect(resumed, isNotNull);
    final List<int> seen = <int>[];
    final Completer<void> done = Completer<void>();
    resumed!.listen(
      (ModelDownloadEvent e) => seen.add(e.receivedBytes),
      onDone: done.complete,
    );
    source.add(ev(100));
    await source.close();
    await done.future;
    expect(seen, <int>[30, 100]);
    expect(shared.attach('moss'), isNull, reason: '下完就从登记表里摘掉');
  });

  test('cancel 才真正停下载；监听方收到 done', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    bool sourceCancelled = false;
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>(
          onCancel: () => sourceCancelled = true,
        );
    final Completer<void> done = Completer<void>();
    shared
        .join('asr:p', () => source.stream)
        .listen((_) {}, onDone: done.complete);
    await pumpEventQueue();
    await shared.cancel('asr:p');
    await done.future;
    expect(sourceCancelled, isTrue);
    expect(shared.isActive('asr:p'), isFalse);
  });

  test('失败转给监听方并释放键，下一次 join 重新起', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>();
    final Completer<Object> failed = Completer<Object>();
    shared
        .join('asr:p', () => source.stream)
        .listen((_) {}, onError: (Object e) => failed.complete(e));
    source.addError(StateError('HTTP 503'));
    expect(await failed.future, isA<StateError>());
    await pumpEventQueue();
    expect(shared.isActive('asr:p'), isFalse);

    int starts = 0;
    final StreamSubscription<ModelDownloadEvent> again = shared
        .join('asr:p', () {
          starts++;
          return const Stream<ModelDownloadEvent>.empty();
        })
        .listen((_) {});
    await pumpEventQueue();
    expect(starts, 1);
    await again.cancel();
  });

  test('歌曲与混音同一个包，但下载单飞键分开（缺分离模型时不能挂到混音那条上算下完）', () {
    final String mixed = asrDownloadKeyFor(
      AsrLanguage.japanese,
      AsrAudioProfile.mixedAudio,
    );
    final String song = asrDownloadKeyFor(
      AsrLanguage.japanese,
      AsrAudioProfile.song,
    );
    expect(
      asrModelPackFor(AsrLanguage.japanese, profile: AsrAudioProfile.song).id,
      asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.mixedAudio,
      ).id,
    );
    expect(song, isNot(mixed));
    expect(song, startsWith(mixed));
  });

  group('歌曲素材那条下载（识别文件只由混音那条写）', () {
    test('混音那条下完、识别文件就绪后才补分离模型；视频页同时在下的混音只起一次', () async {
      final SharedModelDownloads shared = SharedModelDownloads();
      final StreamController<ModelDownloadEvent> mixedSource =
          StreamController<ModelDownloadEvent>();
      int mixedStarts = 0;
      int songStarts = 0;
      AsrEncoderVariant? songVariant;
      bool ready = false;
      Stream<ModelDownloadEvent> mixed() {
        mixedStarts++;
        return mixedSource.stream;
      }

      // 视频页先起了混音那条。
      final List<ModelDownloadEvent> videoSeen = <ModelDownloadEvent>[];
      shared.join('asr:p', mixed).listen(videoSeen.add);
      final List<ModelDownloadEvent> songSeen = <ModelDownloadEvent>[];
      final Completer<void> songDone = Completer<void>();
      joinSongModelDownload(
        shared,
        mixedKey: 'asr:p',
        songKey: 'asr:p+vocals',
        downloadMixedMissing: mixed,
        // 有独显的机器：推荐 fp32，但在盘的是 int8（BUG-5292）。
        mixedReadyVariant: () async => ready ? AsrEncoderVariant.int8 : null,
        downloadSongMissing: (AsrEncoderVariant variant) {
          songStarts++;
          songVariant = variant;
          return Stream<ModelDownloadEvent>.value(ev(100));
        },
      ).listen(songSeen.add, onDone: songDone.complete);
      await pumpEventQueue();
      expect(songStarts, 0, reason: '识别文件没下完前不碰分离模型');

      mixedSource.add(ev(50));
      ready = true;
      await mixedSource.close();
      await songDone.future;
      expect(mixedStarts, 1, reason: '同一批识别文件只有一个写者');
      expect(songStarts, 1);
      expect(
        songVariant,
        AsrEncoderVariant.int8,
        reason: '只补分离模型：按混音包在盘的识别变体下，不按推荐变体重下整套识别权重',
      );
      expect(songSeen.map((ModelDownloadEvent e) => e.receivedBytes), <int>[
        50,
        100,
      ]);
      expect(shared.isActive('asr:p+vocals'), isFalse);
    });

    test('混音那条被取消（设置页按包取消）：歌曲那条随之结束，不由它接着去写识别文件', () async {
      final SharedModelDownloads shared = SharedModelDownloads();
      final StreamController<ModelDownloadEvent> mixedSource =
          StreamController<ModelDownloadEvent>();
      int songStarts = 0;
      final Completer<void> songDone = Completer<void>();
      joinSongModelDownload(
        shared,
        mixedKey: 'asr:p',
        songKey: 'asr:p+vocals',
        downloadMixedMissing: () => mixedSource.stream,
        mixedReadyVariant: () async => null,
        downloadSongMissing: (AsrEncoderVariant _) {
          songStarts++;
          return const Stream<ModelDownloadEvent>.empty();
        },
      ).listen((_) {}, onDone: songDone.complete);
      await pumpEventQueue();
      expect(shared.isActive('asr:p'), isTrue);

      await shared.cancel('asr:p');
      await songDone.future;
      expect(songStarts, 0);
      expect(shared.isActive('asr:p+vocals'), isFalse);
    });
  });

  test('歌曲那条的单飞键 = 包键 + 后缀（设置页按包取消时据此一并停掉）', () {
    final String packId = asrModelPackFor(
      AsrLanguage.japanese,
      profile: AsrAudioProfile.song,
    ).id;
    expect(
      asrDownloadKeyFor(AsrLanguage.japanese, AsrAudioProfile.song),
      asrPackSongDownloadKey(packId),
    );
  });
}
