// HBK-AUDIT-009（#2323 / #2339）：有声书导入收尾的「整书重切（alignPositions FFI）+ 换正文 +
// 能量吸附」原先在调用方（导入对话框 = UI isolate）上同步跑。现在 finalizeAlignedCues 把这一段
// 整体交给后台 isolate。这里钉两件事：
// 1. 结果与改动前的同步路径（同一组构件按原顺序在本 isolate 上直接调用）逐字段一致；
// 2. 计算确实经后台入口：执行计算的 isolate 是 kAlignedCueIsolateName，且调用方传入的
//    cue 对象没被就地改动（计算发生在拷贝上）。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 正文三句；听写一条 cue 横跨第二、三句且没有句号，另一条完全命中第四句。
const String _book = 'たとえば、夢見る時がある。転入生がやってくる。その子はとても素敵な子だと思った。';
const String _heard = '夢見る時がある転入生がやってくる';
// 听写有一处错字（は→わ）：模糊命中，重切要在后台 isolate 里走编辑距离位置对齐
// （ffc_text_align_positions），顺带证明 fushi_compute 在工作 isolate 里能加载。
const String _heard2 = 'その子わとても素敵な子だと思った';
const List<EpubSection> _sections = <EpubSection>[
  EpubSection(index: 0, href: 'ch0.xhtml', text: _book),
];

/// 每次新建（同步参照路径会就地改 cue，两条路径不能共用对象）。
List<AudioCue> _cues() => <AudioCue>[
  AudioCue()
    ..bookKey = 'b'
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = _heard
    ..startMs = 10000
    ..endMs = 13500
    ..audioFileIndex = 0
    ..tokenTiming = CueTokenTiming(
      tokens: _heard.split(''),
      offsetsMs: <int>[
        for (int i = 0; i < 7; i++) 100 + i * 100,
        for (int i = 0; i < 9; i++) 2000 + i * 100,
      ],
    ),
  AudioCue()
    ..bookKey = 'b'
    ..chapterHref = ''
    ..sentenceIndex = 1
    ..textFragmentId = ''
    ..text = _heard2
    ..startMs = 13500
    ..endMs = 16000
    ..audioFileIndex = 0
    ..tokenTiming = CueTokenTiming(
      tokens: _heard2.split(''),
      offsetsMs: <int>[for (int i = 0; i < _heard2.length; i++) 300 + i * 120],
    ),
];

/// cue 与匹配结果的规范文本（逐字段）。
String _describe(List<AudioCue> cues, MatchResult result) {
  final StringBuffer out = StringBuffer();
  for (int k = 0; k < cues.length; k++) {
    final AudioCue c = cues[k];
    final CueMatch m = result.matches[k];
    out.writeln(
      '${c.sentenceIndex}|${c.startMs}|${c.endMs}|${c.text}|'
      '${c.textFragmentId}|${c.tokenTiming?.tokens.join(',')}|'
      '${c.tokenTiming?.offsetsMs.join(',')}|'
      '${m.matched ? '${m.sectionIndex}:${m.normCharStart}-${m.normCharEnd}@${m.score}' : '-'}',
    );
  }
  out.write('${result.matchedCues}/${result.totalCues}');
  return out.toString();
}

void main() {
  late Directory job;
  late String srt;
  setUp(() {
    job = Directory.systemTemp.createTempSync('finalize_isolate_');
    srt = p.join(job.path, AsrJobFiles.srt);
    File(srt).writeAsStringSync(serializeAudioCuesToSrt(_cues()));
    // 单音频 20 s；能量包络：整体有声（−20 dB），句间与段落间各有一段真实停顿。
    File(
      p.join(job.path, AsrJobFiles.state),
    ).writeAsStringSync('{"fileDurationsMs":[20000]}');
    final Int8List energy = Int8List(20000 ~/ kAsrEnergyFrameMs)
      ..fillRange(0, 20000 ~/ kAsrEnergyFrameMs, -20);
    for (final (int a, int b) in <(int, int)>[
      (9600, 10000),
      (11500, 11800),
      (13300, 13700),
      (15900, 16400),
    ]) {
      energy.fillRange(a ~/ kAsrEnergyFrameMs, b ~/ kAsrEnergyFrameMs, -70);
    }
    File(asrEnergyEnvelopePath(job, 0)).writeAsBytesSync(energy);
  });
  tearDown(() => job.deleteSync(recursive: true));

  test('后台收尾与改动前的同步路径逐字段一致，且计算在后台 isolate 的拷贝上进行', () async {
    // 改动前的同步路径：同一组构件按原顺序在本 isolate 上直接调。
    List<AudioCue> refCues = _cues();
    MatchResult refResult = EpubCueMatcher.match(
      sections: _sections,
      cues: refCues,
    );
    expect(refResult.matchedCues, 2, reason: '语料应当命中，否则后面全是空壳断言');
    final CueResegmentResult resegmented = const CueSentenceResegmenter()
        .resegment(sections: _sections, cues: refCues, result: refResult);
    refCues = resegmented.cues;
    refResult = resegmented.result;
    replaceMatchedCueTextWithBookText(
      sections: _sections,
      cues: refCues,
      result: refResult,
    );
    final Int8List energy = readAsrEnergyTimeline(job)!;
    const CueEnergySnapper snapper = CueEnergySnapper();
    final int moved = snapper.snap(refCues, energy);
    final int edges = snapper.refineEdges(refCues, energy);
    expect(moved + edges, greaterThan(0), reason: '能量吸附必须真的改了时间，否则对拍不到它');
    final ({List<AudioCue> cues, MatchResult result, int merged}) merged =
        const CueFragmentMerger().merge(cues: refCues, result: refResult);
    refCues = merged.cues;
    refResult = merged.result;
    final int margins = const CueDisplayMargins().apply(refCues, energy);
    expect(margins, greaterThan(0), reason: '显示余量必须真的改了时间，否则对拍不到它');
    SubtitleRematchCodec.applyToCues(cues: refCues, result: refResult);

    final List<AudioCue> input = _cues();
    final MatchResult matched = EpubCueMatcher.match(
      sections: _sections,
      cues: input,
    );
    debugLastAlignedCueIsolate = null;
    final ({List<AudioCue> cues, MatchResult result}) out =
        await finalizeAlignedCues(
          sections: _sections,
          cues: input,
          result: matched,
          subtitlePath: srt,
          hasTokenTiming: true,
        );

    expect(_describe(out.cues, out.result), _describe(refCues, refResult));
    expect(out.cues.length, 3, reason: '重切应当把横跨两句的 cue 切开');
    expect(debugLastAlignedCueIsolate, kAlignedCueIsolateName);
    expect(Isolate.current.debugName, isNot(kAlignedCueIsolateName));
    // 计算发生在拷贝上：调用方的 cue 对象原封不动（同步路径会就地换文本、改时间）。
    expect(input.first.text, _heard);
    expect(input.first.startMs, 10000);
    expect(input.first.endMs, 13500);
  });

  test('两步都不需要（非转录产物、无 token 时间）时不派发后台，原列表原样返回', () async {
    final String plain = p.join(job.path, 'plain.srt');
    File(plain).writeAsStringSync(serializeAudioCuesToSrt(_cues()));
    final List<AudioCue> input = _cues();
    final MatchResult matched = EpubCueMatcher.match(
      sections: _sections,
      cues: input,
    );
    debugLastAlignedCueIsolate = null;
    final ({List<AudioCue> cues, MatchResult result}) out =
        await finalizeAlignedCues(
          sections: _sections,
          cues: input,
          result: matched,
          subtitlePath: plain,
          hasTokenTiming: false,
        );
    expect(identical(out.cues, input), isTrue);
    expect(debugLastAlignedCueIsolate, isNull);
    expect(out.cues.first.text, _heard);
  });
}
