/// Android 模拟器 / 真机：语音模型「下载 → 中断 → 续传 → 就绪 → 真转录」端到端。
///
/// 用户报告（2026-09-08，Android）：设置页显示模型已下载，但转录弹层里选不了 /
/// 用不了；怀疑此前网络中断导致模型没下完。本测试用**生产装配**
/// （`installAsrHostBindings()` + `createAsrTranscriptionService()`，与 `main()` /
/// 设置页 / 转录弹层同一份）在设备上复现这条路径：
///
/// 1. 从空目录起真网络下载（主源 → hf-mirror 回退都走真实候选序列）；下到编码器
///    ≥ 2 MB 时**取消订阅**（= 用户断网 / 离开设置页），断言 `.part` 留在盘上、
///    `plan()` 报「部分」而非「就绪」；
/// 2. 再次下载：Range 续传到完成；断言每个文件长度 == 清单 `expectedBytes`、
///    `plan()` 报就绪；
/// 3. 用就绪的模型对设备上的 `ja_tts_16k.wav` 真转录（后台 isolate + PCM 桥 +
///    ffmpeg-kit + ORT Android），断言识别出「今日はいい天気ですね」；
/// 4. 把真服务塞进真的 [AsrTranscribeSheet]，断言弹层判出「模型就绪」+「开始转录」
///    按钮（用户看到的那一层）。
///
/// 输入（`--dart-define`）：
///   ASR_MODE=network|seed   network（缺省）= 真网络下载；seed = 不联网，从
///                           ASR_SEED_DIR 拷一套 int8 模型进生产模型目录（网络
///                           不可用时仍能验 3 / 4）
///   ASR_SEED_DIR=<dir>      设备上的模型目录（缺省 `<support>/asr_seed/reazonspeech-k2-v2`）
///   ASR_AUDIO=<wav>         设备上的音频（缺省 `<support>/asr_e2e/ja_tts_16k.wav`）
///
/// 跑法（从 fushi/，模拟器序列号按 `adb devices`；素材经 `run-as` 写进 app 内部
/// `files/`——/sdcard/Android/data 下由 shell 建的目录 app 自己 stat 会 EACCES）：
///   adb push <file> /data/local/tmp/x && adb shell 'cat /data/local/tmp/x | run-as app.fushi.reader sh -c "cat > files/asr_seed/reazonspeech-k2-v2/<file>"'
///   flutter test integration_test/asr_android_model_ready_itest.dart -d emulator-5554 --no-pub --timeout none
library;

import 'dart:async';
import 'dart:io';

import 'package:asr_core/asr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/utils.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

const String _kMode =
    String.fromEnvironment('ASR_MODE', defaultValue: 'network');

/// 种子模型目录 / 音频：缺省落在 app 数据根（`<support>/asr_seed/<pack.id>` /
/// `<support>/asr_e2e/ja_tts_16k.wav`，Android 上 = `/data/user/0/<pkg>/files/…`，
/// 用 `run-as` 写入——/sdcard/Android/data 由 shell 建的目录 app 自己读不了）。
const String _kSeedDirOverride = String.fromEnvironment('ASR_SEED_DIR');
const String _kAudioOverride = String.fromEnvironment('ASR_AUDIO');
const AsrLanguage _kLang = AsrLanguage.japanese;
const String _kExpect = '今日はいい天気ですね';

/// 取消点：编码器文件已收到这么多字节就掐断（模拟断网）。
const int _kCancelAfterBytes = 2 * 1024 * 1024;

void _log(String message) {
  // ignore: avoid_print
  print('[asr-android] $message');
}

String _normalize(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\s、。！？!?,.\x27"“”’]'), '');

/// 模型目录当前状态一行（就绪 / 每个文件的实际长度 / `.part` 残留）。
String _describeStore(AsrModelStore store, AsrEncoderVariant variant) {
  final StringBuffer sb = StringBuffer();
  sb.write(
      'dir=${store.dir.path} ready(${variant.name})=${store.isReady(variant)}');
  if (store.dir.existsSync()) {
    for (final FileSystemEntity e in store.dir.listSync()) {
      if (e is File) {
        sb.write(' ${p.basename(e.path)}=${e.lengthSync()}');
      }
    }
  }
  return sb.toString();
}

/// 下载到编码器收到 [_kCancelAfterBytes] 字节就取消订阅（与设置页「取消」/
/// 用户断网离开是同一条路：`StreamSubscription.cancel()`）。返回取消时的事件。
Future<ModelDownloadEvent?> _downloadThenCancel(
  AsrTranscriptionService service,
  AsrTranscribePlan plan,
) async {
  final Completer<ModelDownloadEvent?> done = Completer<ModelDownloadEvent?>();
  late final StreamSubscription<ModelDownloadEvent> sub;
  sub = service
      .downloadModel(language: plan.language, variant: plan.variant)
      .listen(
    (ModelDownloadEvent e) {
      if (done.isCompleted) return;
      if (e.receivedBytes >= _kCancelAfterBytes && !e.done) {
        _log('cancelling at ${e.fileName} ${e.receivedBytes}/${e.totalBytes}');
        unawaited(sub.cancel());
        done.complete(e);
      }
    },
    onError: (Object error, StackTrace stack) {
      _log('download error before cancel point: $error');
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(null);
    },
  );
  return done.future;
}

/// 跑完整下载（续传）；每 8 MB 打一行进度。
Future<void> _downloadToEnd(
  AsrTranscriptionService service,
  AsrTranscribePlan plan,
) async {
  int lastLogged = -1;
  String lastFile = '';
  await for (final ModelDownloadEvent e in service.downloadModel(
    language: plan.language,
    variant: plan.variant,
  )) {
    if (e.fileName != lastFile ||
        e.done ||
        e.receivedBytes - lastLogged >= 8 * 1024 * 1024) {
      _log('progress ${e.fileName} ${e.receivedBytes}/${e.totalBytes}'
          '${e.done ? ' done' : ''}');
      lastFile = e.fileName;
      lastLogged = e.receivedBytes;
    }
  }
}

Future<void> _seedFrom(Directory seed, AsrModelStore store) async {
  expect(seed.existsSync(), isTrue, reason: '种子模型目录不存在：${seed.path}');
  await store.dir.create(recursive: true);
  for (final AsrModelFile file in store.pack.filesFor(AsrEncoderVariant.int8)) {
    final File src = File(p.join(seed.path, file.fileName));
    expect(src.existsSync(), isTrue, reason: '种子缺文件：${src.path}');
    await src.copy(store.fileFor(file.role).path);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AsrTranscriptionService service;
  late AsrModelStore store;
  late String seedDir;
  late String audio;

  setUpAll(() async {
    // 与 main() 同序：先装 asr_core 三个装配点，再把代理表准备好。
    installAsrHostBindings();
    await primeAppProxy();
    service = createAsrTranscriptionService();
    store = await service.modelStore(_kLang);
    final Directory support = await asrSupportRootDirectory();
    seedDir = _kSeedDirOverride.isNotEmpty
        ? _kSeedDirOverride
        : p.join(support.path, 'asr_seed', store.pack.id);
    audio = _kAudioOverride.isNotEmpty
        ? _kAudioOverride
        : p.join(support.path, 'asr_e2e', 'ja_tts_16k.wav');
    _log('mode=$_kMode seed=$seedDir audio=$audio '
        '${_describeStore(store, AsrEncoderVariant.int8)}');
  });

  testWidgets(
    '真网络下载：中断留 .part、plan 报部分；续传后每个文件长度等于清单、plan 报就绪',
    (WidgetTester tester) async {
      if (_kMode != 'network') {
        _log('ASR_MODE=$_kMode，跳过网络下载用例');
        return;
      }
      if (store.dir.existsSync()) {
        await store.dir.delete(recursive: true);
      }
      final AsrTranscribePlan fresh = await service.plan(
        language: _kLang,
        preference: AsrAccelerationPreference.auto,
      );
      _log('plan(fresh) variant=${fresh.variant.name} '
          'ep=${fresh.expectedProvider.name} ready=${fresh.modelReady} '
          'obtained=${fresh.modelStatus.obtainedBytes}/'
          '${fresh.modelStatus.totalBytes} probeError=${fresh.probeError}');
      expect(fresh.modelReady, isFalse);
      expect(fresh.modelStatus.obtainedBytes, 0);

      // 1. 下到一半掐断。
      final ModelDownloadEvent? cancelledAt =
          await _downloadThenCancel(service, fresh);
      expect(cancelledAt, isNotNull, reason: '还没到取消点下载就结束了');
      // 取消是异步的：等下载器把 sink 关掉、.part 长度稳定。
      await Future<void>.delayed(const Duration(seconds: 2));
      final File part =
          File('${store.fileFor(asrEncoderRole(fresh.variant)).path}.part');
      _log('after cancel: ${_describeStore(store, fresh.variant)}');
      expect(part.existsSync(), isTrue, reason: '取消后 .part 应留在盘上');
      expect(part.lengthSync(), greaterThan(0));
      expect(store.isReady(fresh.variant), isFalse);

      final AsrTranscribePlan partial = await service.plan(
        language: _kLang,
        preference: AsrAccelerationPreference.auto,
      );
      _log('plan(partial) ready=${partial.modelReady} '
          'obtained=${partial.modelStatus.obtainedBytes}/'
          '${partial.modelStatus.totalBytes} '
          'toDownload=${partial.bytesToDownload}');
      expect(partial.modelReady, isFalse);
      expect(partial.modelStatus.obtainedBytes, part.lengthSync());
      expect(partial.variant, fresh.variant, reason: '两次 plan 推荐的变体必须一致');

      // 2. 续传到完成。
      await _downloadToEnd(service, partial);
      _log('after resume: ${_describeStore(store, fresh.variant)}');
      for (final AsrModelFile file in store.pack.filesFor(fresh.variant)) {
        final File f = store.fileFor(file.role);
        expect(f.existsSync(), isTrue, reason: '缺 ${file.fileName}');
        expect(
          f.lengthSync(),
          file.expectedBytes,
          reason: '${file.fileName} 长度与清单不符',
        );
        expect(File('${f.path}.part').existsSync(), isFalse);
      }
      final AsrTranscribePlan ready = await service.plan(
        language: _kLang,
        preference: AsrAccelerationPreference.auto,
      );
      _log('plan(ready) ready=${ready.modelReady} '
          'obtained=${ready.modelStatus.obtainedBytes}/'
          '${ready.modelStatus.totalBytes} disk=${ready.modelStatus.diskBytes}');
      expect(ready.modelReady, isTrue);
      expect(ready.variant, fresh.variant);
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );

  testWidgets(
    '就绪模型真转录：后台 isolate + PCM 桥 + ORT Android 读出日语',
    (WidgetTester tester) async {
      if (!store.isReady(AsrEncoderVariant.int8)) {
        _log('模型未就绪，从种子目录拷入：$seedDir');
        await _seedFrom(Directory(seedDir), store);
      }
      _log(_describeStore(store, AsrEncoderVariant.int8));
      expect(File(audio).existsSync(), isTrue, reason: '音频不存在：$audio');

      final AsrTranscribePlan plan = await service.plan(
        language: _kLang,
        preference: AsrAccelerationPreference.auto,
      );
      expect(plan.modelReady, isTrue, reason: 'plan 未判就绪');
      await service.discard(<String>[audio], _kLang);

      final Stopwatch load = Stopwatch()..start();
      final AsrRunningTranscription running = await service.start(
        audioPaths: <String>[audio],
        language: _kLang,
        variant: plan.variant,
        preference: AsrAccelerationPreference.auto,
      );
      load.stop();
      _log('engine loaded in ${load.elapsedMilliseconds}ms '
          'resolution=${running.encoderResolution} '
          'greedy=${running.greedyGraphAvailable} '
          '(${running.greedyUnavailableReason})');
      AsrTranscribeResult? result;
      try {
        await for (final AsrTranscribeEvent e in running.run()) {
          if (e is AsrTranscribeProgressEvent) {
            _log('progress processedMs=${e.progress.processedMs} '
                'segments=${e.progress.segmentsDone}');
          }
          if (e is AsrTranscribeFinishedEvent) result = e.result;
        }
      } finally {
        await running.dispose();
      }
      expect(result, isNotNull, reason: '任务没有以 finished 结束');
      final List<AsrTranscribedSegment> segments =
          await AsrTranscribeJob.loadSegments(
        await service.jobDirFor(<String>[audio], _kLang),
      );
      final String text =
          segments.map((AsrTranscribedSegment s) => s.text).join();
      _log(
          'transcript: "$text" cues=${result!.cueCount} srt=${result.srtPath}');
      expect(File(result.srtPath).lengthSync(), greaterThan(0));
      expect(_normalize(text), contains(_normalize(_kExpect)));
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  testWidgets(
    '转录弹层拿真服务：判出「模型就绪」并给出「开始转录」按钮',
    (WidgetTester tester) async {
      expect(store.isReady(AsrEncoderVariant.int8), isTrue);
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: AsrTranscribeSheet(
                  audioPaths: <String>[audio],
                  service: service,
                  languageGetter: () => _kLang.tag,
                  languageSetter: (String _) async {},
                ),
              ),
            ),
          ),
        ),
      );
      // plan() 真走 EP 探测 + 目录量算；轮询到弹层离开「准备中」。
      final Finder start =
          find.widgetWithText(FilledButton, t.audiobook_transcribe_start);
      final Stopwatch sw = Stopwatch()..start();
      while (start.evaluate().isEmpty &&
          sw.elapsed < const Duration(seconds: 60)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final String status = tester
          .widget<Text>(
              find.byKey(const ValueKey<String>('asr-transcribe-status')))
          .data!;
      _log('sheet status after ${sw.elapsedMilliseconds}ms: "$status"');
      expect(start, findsOneWidget, reason: '弹层没给出「开始转录」：$status');
      expect(
        find.widgetWithText(
            FilledButton, t.audiobook_transcribe_model_download),
        findsNothing,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
