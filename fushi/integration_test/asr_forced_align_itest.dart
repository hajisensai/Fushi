/// CTC 强制对齐原型的真模型端到端：EPUB + 我们的 SRT（可带 token sidecar）
/// → 匹配 / 重切 / 换正文 → 每条命中 cue 用 **正文文本 + Omnilingual CTC** 做
/// Viterbi 强制对齐，得到逐字起止帧 → 与参照 SRT 比起点 |Δ|（对齐前 / 后）。
///
/// 这是「cue 边界准不准」这条线的量具：转录 cue 的边界来自 RNN-T 发射时间
/// （系统性偏晚）与 VAD 边缘，2026-09-07 かがみの孤城 20 分钟对参照 p50 = 410 ms；
/// 强制对齐拿正文当已知文本、只求时间，理论上能把边界钉到帧级。
///
/// 参数（环境变量或 --dart-define）：
///   ASR_MODEL_SEED   Omnilingual 1B CTC 模型目录（model.onnx + model.weights /
///                    model.int8.onnx + tokens.txt + silero_vad.onnx）
///   ASR_AUDIO        音频（与 SRT 同一时间轴）
///   ASR_ALIGN_EPUB   EPUB
///   ASR_ALIGN_SRT    我们的 SRT（旁边若有 `<同名>.tokens.jsonl` 则先按句界重切）
///   ASR_ALIGN_REF    参照 SRT（可缺省：只报对齐成功率与耗时）
///   ASR_ALIGN_LIMIT_MS / ASR_ALIGN_MAX_CUES   只处理前面一段
///   ASR_ALIGN_PAD_MS 切 PCM 时两侧各留的余量（默认 500）
///   ASR_ALIGN_ONLY   gpu | cpu（默认 gpu：fp32 + 显存；cpu：int8）
///   ASR_OUT          把对齐后的 SRT 写到该目录（aligned.srt）
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_ctc_align.dart';
import 'package:fushi/src/asr/asr_ctc_decoder.dart';
import 'package:fushi/src/asr/asr_cue_builder.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/media/audiobook/audiobook_alignment_service.dart'
    show epubSectionsFromBook;

String _param(String name, {String defaultValue = ''}) {
  final String fromDefine = switch (name) {
    'ASR_MODEL_SEED' => const String.fromEnvironment('ASR_MODEL_SEED'),
    'ASR_AUDIO' => const String.fromEnvironment('ASR_AUDIO'),
    'ASR_ALIGN_EPUB' => const String.fromEnvironment('ASR_ALIGN_EPUB'),
    'ASR_ALIGN_SRT' => const String.fromEnvironment('ASR_ALIGN_SRT'),
    'ASR_ALIGN_REF' => const String.fromEnvironment('ASR_ALIGN_REF'),
    'ASR_OUT' => const String.fromEnvironment('ASR_OUT'),
    _ => '',
  };
  if (fromDefine.isNotEmpty) return fromDefine;
  final String? fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return defaultValue;
}

void _log(String msg) {
  // ignore: avoid_print
  print('[asr-align] $msg');
}

/// 正文 → 对齐用文本：只留字母/数字类字符（标点、空白、引号不发声；片假名 / 汉字
/// 原样保留——词表区分片假名与平假名，不能像匹配归一化那样折叠）。
String _alignText(String text) =>
    text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

int _nearest(List<int> sorted, int value) {
  int lo = 0;
  int hi = sorted.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (sorted[mid] < value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  int best = 1 << 30;
  for (final int k in <int>[lo - 1, lo]) {
    if (k >= 0 && k < sorted.length) {
      best = math.min(best, (sorted[k] - value).abs());
    }
  }
  return best;
}

String _pcts(List<int> diffs) {
  if (diffs.isEmpty) return 'n=0';
  final List<int> d = List<int>.of(diffs)..sort();
  int pct(int q) => d[(d.length - 1) * q ~/ 100];
  return 'p50=${pct(50)}ms p80=${pct(80)}ms p95=${pct(95)}ms max=${d.last}ms '
      'n=${d.length}';
}

String _srtTime(int ms) {
  final int c = math.max(0, ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(c ~/ 3600000)}:${two(c % 3600000 ~/ 60000)}:'
      '${two(c % 60000 ~/ 1000)},${(c % 1000).toString().padLeft(3, '0')}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String seed = _param('ASR_MODEL_SEED');
  final String audio = _param('ASR_AUDIO');
  final String epubPath = _param('ASR_ALIGN_EPUB');
  final String srtPath = _param('ASR_ALIGN_SRT');
  final String refPath = _param('ASR_ALIGN_REF');
  final int limitMs = int.tryParse(_param('ASR_ALIGN_LIMIT_MS')) ?? (1 << 62);
  final int maxCues = int.tryParse(_param('ASR_ALIGN_MAX_CUES')) ?? (1 << 30);
  final int padMs = int.tryParse(_param('ASR_ALIGN_PAD_MS')) ?? 500;
  final bool cpuOnly = _param('ASR_ALIGN_ONLY') == 'cpu';

  testWidgets('CTC 强制对齐：正文文本 → 逐字起止帧 → cue 边界', (
    WidgetTester tester,
  ) async {
    expect(seed, isNotEmpty, reason: '需要 ASR_MODEL_SEED');
    for (final String f in <String>[audio, epubPath, srtPath]) {
      expect(File(f).existsSync(), isTrue, reason: '文件不存在：$f');
    }
    final AsrModelStore store = AsrModelStore(
      Directory(seed),
      kAsrOmnilingualPack,
    );
    final AsrEncoderVariant variant =
        cpuOnly ? AsrEncoderVariant.int8 : AsrEncoderVariant.fp32;
    expect(store.isReady(variant), isTrue, reason: '模型不全：$seed');

    // 1. EPUB → 章节（带 ruby 读音轨）。
    final Directory extract = await Directory.systemTemp.createTemp(
      'asr_align_epub_',
    );
    final Directory work = await Directory.systemTemp.createTemp('asr_align_');
    AsrEngineSessions? sessions;
    try {
      final EpubBook book =
          EpubParser.parseSyncFromPath(epubPath, extract.path);
      final List<EpubSection> sections = epubSectionsFromBook(book);

      // 2. cue：解析 → sidecar → 匹配 + 回填 → 句界重切 → 换正文。
      List<AudioCue> cues = (await SrtParser.parse(
        srtFile: File(srtPath),
        bookKey: 'align',
      ))
          .where((AudioCue c) => c.startMs < limitMs)
          .take(maxCues)
          .toList();
      final File sidecar = File(
        srtPath.replaceAll(RegExp(r'\.srt$'), '.tokens.jsonl'),
      );
      bool hasTiming = false;
      if (sidecar.existsSync()) {
        final List<({List<String> tokens, List<int> offsetsMs})>? rows =
            parseAsrCueTokens(await sidecar.readAsString());
        if (rows != null && rows.length >= cues.length) {
          for (int i = 0; i < cues.length; i++) {
            cues[i].tokenTiming = CueTokenTiming(
              tokens: rows[i].tokens,
              offsetsMs: rows[i].offsetsMs,
            );
          }
          hasTiming = true;
        }
      }
      MatchResult result = EpubCueMatcher.match(
        sections: sections,
        cues: cues,
        similarityThreshold: kAsrSuggestedSimilarityThreshold,
      );
      if (hasTiming) {
        final CueResegmentResult r = const CueSentenceResegmenter().resegment(
          sections: sections,
          cues: cues,
          result: result,
        );
        cues = r.cues;
        result = r.result;
        _log('resegment ${r.stats}');
      }
      replaceMatchedCueTextWithBookText(
        sections: sections,
        cues: cues,
        result: result,
      );
      _log(
        'cues=${cues.length} matched=${result.matchedCues} '
        'sections=${sections.length}',
      );

      // 3. 整段 PCM 进内存（20 分钟 ≈ 77 MB float32）。
      final Stopwatch pcmClock = Stopwatch()..start();
      final List<AsrPcmChunk> chunks =
          await FfmpegAsrPcmSource().decode(audio, chunkSeconds: 600).toList();
      final int totalSamples = chunks.fold<int>(
        0,
        (int a, AsrPcmChunk c) => a + c.samples.length,
      );
      final Float32List pcm = Float32List(totalSamples);
      int at = 0;
      for (final AsrPcmChunk c in chunks) {
        pcm.setRange(at, at + c.samples.length, c.samples);
        at += c.samples.length;
      }
      _log(
        'pcm samples=$totalSamples (${totalSamples ~/ kAsrSampleRate} s) '
        'decode=${pcmClock.elapsedMilliseconds}ms',
      );

      // 4. 装载 CTC 模型（动态会话；对齐一段一次 run，不用静态桶）。
      final Stopwatch loadClock = Stopwatch()..start();
      sessions = await AsrEngineLoader().load(
        store: store,
        variant: variant,
        preference: cpuOnly
            ? AsrAccelerationPreference.cpuOnly
            : AsrAccelerationPreference.auto,
        useGreedyGraph: false,
        useStaticEncoderBuckets: false,
        useFp16Encoder: false,
      );
      _log(
        'engine ${variant.name} ${sessions.encoderResolution} '
        'load=${loadClock.elapsedMilliseconds}ms',
      );
      final AsrCtcDecoder decoder = AsrCtcDecoder(
        model: sessions.encoder,
        tokens: sessions.tokens,
      );
      final AsrCtcTextEncoder encoder = AsrCtcTextEncoder(sessions.tokens);
      expect(encoder.isSupported, isTrue);

      // 5. 逐 cue 对齐。
      final List<int> refStarts = <int>[];
      final List<int> refEnds = <int>[];
      if (refPath.isNotEmpty && File(refPath).existsSync()) {
        for (final AudioCue c in await SrtParser.parse(
          srtFile: File(refPath),
          bookKey: 'ref',
        )) {
          refStarts.add(c.startMs);
          refEnds.add(c.endMs);
        }
        refStarts.sort();
        refEnds.sort();
      }
      final List<int> beforeStart = <int>[];
      final List<int> afterStart = <int>[];
      final List<int> beforeEnd = <int>[];
      final List<int> afterEnd = <int>[];
      final List<int> moved = <int>[];
      final List<double> confidences = <double>[];
      int aligned = 0;
      int failed = 0;
      int skipped = 0;
      int droppedChars = 0;
      int totalChars = 0;
      final Stopwatch alignClock = Stopwatch()..start();
      int runMs = 0;
      final StringBuffer srtOut = StringBuffer();
      int srtIndex = 1;
      for (int i = 0; i < cues.length; i++) {
        final AudioCue cue = cues[i];
        int newStart = cue.startMs;
        int newEnd = cue.endMs;
        if (result.matches[i].matched) {
          final String text = _alignText(cue.text);
          final AsrCtcEncodedText enc = encoder.encode(text);
          totalChars += text.runes.length;
          droppedChars += text.runes.length - enc.length;
          final int s0 =
              math.max(0, cue.startMs - padMs) * kAsrSampleRate ~/ 1000;
          final int s1 = math.min(
            totalSamples,
            (cue.endMs + padMs) * kAsrSampleRate ~/ 1000,
          );
          // 长度凑到整 2 s（减少动态会话的形状种类），Omnilingual 上限 40 s。
          final int len = s1 - s0;
          final int padded = math.min(
              40 * kAsrSampleRate,
              (len + 2 * kAsrSampleRate - 1) ~/
                  (2 * kAsrSampleRate) *
                  2 *
                  kAsrSampleRate);
          if (enc.isEmpty || len <= 0 || len > 40 * kAsrSampleRate) {
            skipped++;
          } else {
            final Float32List slice = Float32List(padded);
            slice.setRange(0, len, pcm, s0);
            final Stopwatch one = Stopwatch()..start();
            final AsrCtcLogits lg = await decoder.runLogits(slice);
            runMs += one.elapsedMilliseconds;
            final int realFrames =
                math.min(lg.frames, (len / lg.frameSamples).ceil());
            final AsrCtcAlignment? a = ctcForcedAlign(
              logits:
                  Float32List.sublistView(lg.logits, 0, realFrames * lg.vocab),
              frames: realFrames,
              vocab: lg.vocab,
              targets: enc.ids,
              blankId: sessions.tokens.blankId,
            );
            if (a == null || a.tokens.isEmpty) {
              failed++;
            } else {
              aligned++;
              final int s0Ms = s0 * 1000 ~/ kAsrSampleRate;
              newStart =
                  s0Ms + (a.tokens.first.startFrame * lg.frameMs).round();
              newEnd = s0Ms + (a.tokens.last.endFrame * lg.frameMs).round();
              confidences.add(a.totalLogProb / a.tokens.length);
              moved.add((newStart - cue.startMs).abs());
              if (refStarts.isNotEmpty) {
                beforeStart.add(_nearest(refStarts, cue.startMs));
                afterStart.add(_nearest(refStarts, newStart));
                beforeEnd.add(_nearest(refEnds, cue.endMs));
                afterEnd.add(_nearest(refEnds, newEnd));
              }
              if (i < 12) {
                _log(
                  '#$i ${cue.startMs}-${cue.endMs} → $newStart-$newEnd '
                  'conf=${(a.totalLogProb / a.tokens.length).toStringAsFixed(2)} '
                  '"${cue.text}"',
                );
              }
            }
          }
        }
        srtOut
          ..write(srtIndex++)
          ..write('\n')
          ..write(_srtTime(newStart))
          ..write(' --> ')
          ..write(_srtTime(math.max(newEnd, newStart + 40)))
          ..write('\n')
          ..write(cue.text.replaceAll('\n', ' '))
          ..write('\n\n');
      }
      alignClock.stop();
      _log(
        'aligned=$aligned failed=$failed skipped=$skipped '
        'chars=$totalChars dropped=$droppedChars '
        'wall=${alignClock.elapsedMilliseconds}ms run=${runMs}ms',
      );
      final List<double> conf = List<double>.of(confidences)..sort();
      if (conf.isNotEmpty) {
        _log(
          'confidence(mean logprob/char) p10=${conf[(conf.length - 1) ~/ 10].toStringAsFixed(2)} '
          'p50=${conf[(conf.length - 1) ~/ 2].toStringAsFixed(2)} '
          'p90=${conf[(conf.length - 1) * 9 ~/ 10].toStringAsFixed(2)}',
        );
      }
      _log('moved start |Δ|: ${_pcts(moved)}');
      if (refStarts.isNotEmpty) {
        _log('start |Δ| vs ref BEFORE: ${_pcts(beforeStart)}');
        _log('start |Δ| vs ref AFTER : ${_pcts(afterStart)}');
        _log('end   |Δ| vs ref BEFORE: ${_pcts(beforeEnd)}');
        _log('end   |Δ| vs ref AFTER : ${_pcts(afterEnd)}');
      }
      final String outDir = _param('ASR_OUT');
      if (outDir.isNotEmpty) {
        await Directory(outDir).create(recursive: true);
        final String dst = p.join(outDir, 'aligned.srt');
        await File(dst).writeAsString(srtOut.toString());
        _log('out $dst');
      }
      expect(aligned, greaterThan(0));
    } finally {
      await sessions?.close();
      if (extract.existsSync()) await extract.delete(recursive: true);
      if (work.existsSync()) await work.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
