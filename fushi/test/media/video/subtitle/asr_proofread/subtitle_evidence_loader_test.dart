import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

/// 一集里的开口时刻（秒，间隔 1.5–6 秒；与 embedded_reference_subtitle_sync_test 同法）。
List<double> _speech(int seed) {
  final math.Random r = math.Random(seed);
  final List<double> out = <double>[];
  double t = 20;
  while (t < 1400) {
    out.add(t);
    t += 1.5 + r.nextDouble() * 4.5;
  }
  return out;
}

/// 按开始时刻生成 SRT（每句 1.2 秒），第 i 句正文 [text](i)。
String _srt(Iterable<double> starts, String Function(int i) text) {
  String ts(double s) {
    final int ms = (s * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two((ms ~/ 60000) % 60)}:'
        '${two((ms ~/ 1000) % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final StringBuffer b = StringBuffer();
  int i = 0;
  for (final double s in starts) {
    b.write('${i + 1}\n${ts(s)} --> ${ts(s + 1.2)}\n${text(i)}\n\n');
    i++;
  }
  return b.toString();
}

/// 识别稿：开口时刻 = [truth]。
List<SubtitleDraftCue> _drafts(List<double> truth) => <SubtitleDraftCue>[
  for (final double t in truth)
    SubtitleDraftCue(
      startMs: (t * 1000).round(),
      endMs: (t * 1000).round() + 1200,
      text: 'あ',
    ),
];

String _en(int i) =>
    i.isOdd ? '♪ I can hear your voice tonight' : 'That song is really good.';

/// 内容是日文（文件名标了别的语言：字幕组标错轨）。
String _ja(int i) => '今日はいい天気ですね、本当に';

const String _ass = '''[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
Style: OP,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}That{\\i0} song.
Dialogue: 0,0:00:05.00,0:00:07.00,OP,,0,0,0,,I can hear your voice
''';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('evload_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('ASS：样式 OP 判歌词，覆盖标签去掉', () {
    final List<SubtitleEvidenceCue> cues = parseSubtitleEvidenceCues(
      SubtitleFormat.ass,
      _ass,
    );
    expect(cues, hasLength(2));
    expect(cues[0].text, 'That song.');
    expect(cues[0].role, SubtitleEvidenceRole.dialogue);
    expect(cues[1].role, SubtitleEvidenceRole.song);
  });

  test('外挂字幕：按文件收证据、判语言；自己的产物不收；宿主登记文件一并收', () async {
    final List<double> truth = _speech(3);
    final String video = p.join(tmp.path, 'ep08.mkv');
    File(video).writeAsBytesSync(<int>[0, 1, 2, 3]);
    // 外挂 en 比视频晚 4 秒（别的压制版本）：对齐后按视频时间收。
    File(
      p.join(tmp.path, 'ep08.en.srt'),
    ).writeAsStringSync(_srt(truth.map((double t) => t + 4), _en));
    File(p.join(tmp.path, 'ep08.ja.srt')).writeAsStringSync(_srt(truth, _ja));
    File(p.join(tmp.path, 'ep08.fr.srt')).writeAsStringSync(_srt(truth, _ja));
    final Directory docs = Directory(p.join(tmp.path, 'docs'))..createSync();
    final String imported = p.join(docs.path, 'abc123.srt');
    File(imported).writeAsStringSync(_srt(truth, _ja));
    final String own = p.join(tmp.path, 'ep08.ja.srt');

    final SubtitleEvidenceCollector collector = SubtitleEvidenceCollector(
      extraSubtitleFiles: (String _) async => <String>[imported],
    );
    final List<SubtitleEvidenceTrack> tracks = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: _drafts(truth),
        isOwnOutput: (String path) => p.equals(path, own),
        targetLanguage: 'ja',
      ),
    );
    final Map<String, SubtitleEvidenceTrack> byLabel =
        <String, SubtitleEvidenceTrack>{
          for (final SubtitleEvidenceTrack t in tracks) t.label: t,
        };
    expect(
      byLabel.keys,
      unorderedEquals(<String>['ep08.en.srt', 'ep08.fr.srt', 'abc123.srt']),
    );
    expect(byLabel['ep08.en.srt']!.language, 'en');
    expect(byLabel['ep08.en.srt']!.cues[1].role, SubtitleEvidenceRole.song);
    // 标 fr、内容是日文：信文字。
    expect(byLabel['ep08.fr.srt']!.language, 'ja');
    expect(byLabel['abc123.srt']!.language, 'ja');
    // 偏移被改写回视频时间轴。
    expect(
      byLabel['ep08.en.srt']!.cues.first.startMs,
      closeTo(truth.first * 1000, 10),
    );

    // 来源身份：改了文件 → key 变。
    final String key1 = await collector.sourceKey(
      video,
      isOwnOutput: (String path) => p.equals(path, own),
    );
    File(
      p.join(tmp.path, 'ep08.en.srt'),
    ).writeAsStringSync('${_srt(truth.map((double t) => t + 4), _en)}\n');
    final String key2 = await collector.sourceKey(
      video,
      isOwnOutput: (String path) => p.equals(path, own),
    );
    expect(key1, isNot(key2));
  });

  test('时间轴对不上的外挂轨不收：判 refused / needsConfirmation、识别稿太短判不了', () async {
    final List<double> truth = _speech(3);
    final String video = p.join(tmp.path, 'ep09.mkv');
    File(video).writeAsBytesSync(<int>[0, 1, 2, 3]);
    // 同语言、但是别的一集（文件名配错集）：开口时刻与本集无关。
    File(
      p.join(tmp.path, 'ep09.jpn.srt'),
    ).writeAsStringSync(_srt(_speech(99), _ja));
    // 对照：时间轴对得上的同语言轨照收。
    File(p.join(tmp.path, 'ep09.ja.srt')).writeAsStringSync(_srt(truth, _ja));
    const SubtitleEvidenceCollector collector = SubtitleEvidenceCollector();

    final List<SubtitleEvidenceTrack> tracks = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: _drafts(truth),
        isOwnOutput: (String _) => false,
        targetLanguage: 'ja',
      ),
    );
    expect(tracks.map((SubtitleEvidenceTrack t) => t.label), <String>[
      'ep09.ja.srt',
    ]);

    // 识别稿相对外挂轨太稀疏（5 行 vs 整集）：对不了时间轴，一条外挂都不收。
    final List<SubtitleEvidenceTrack> short = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: _drafts(truth.take(5).toList()),
        isOwnOutput: (String _) => false,
        targetLanguage: 'ja',
      ),
    );
    expect(short, isEmpty);
  });

  test('短片（识别稿少于 30 行）：时间轴对得上的外挂轨照收并按识别稿改写时间', () async {
    // 90 秒短片，开口间隔 3–6 秒：二十来句。
    final math.Random r = math.Random(41);
    final List<double> truth = <double>[];
    for (double t = 2; t < 88; t += 3 + r.nextDouble() * 3) {
      truth.add(t);
    }
    expect(truth.length, lessThan(30));
    final String video = p.join(tmp.path, 'clip.mkv');
    File(video).writeAsBytesSync(<int>[0, 1, 2, 3]);
    // 外挂字幕整体晚 2 秒（给别的压制版做的）。
    File(
      p.join(tmp.path, 'clip.ja.srt'),
    ).writeAsStringSync(_srt(truth.map((double t) => t + 2), _ja));
    // 别的短片的字幕：不收。
    final math.Random o = math.Random(77);
    final List<double> other = <double>[];
    for (double t = 3; t < 88; t += 3 + o.nextDouble() * 3) {
      other.add(t);
    }
    File(p.join(tmp.path, 'clip.jpn.srt')).writeAsStringSync(_srt(other, _ja));
    const SubtitleEvidenceCollector collector = SubtitleEvidenceCollector();

    final List<SubtitleEvidenceTrack> tracks = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: _drafts(truth),
        isOwnOutput: (String _) => false,
        targetLanguage: 'ja',
      ),
    );
    expect(tracks.map((SubtitleEvidenceTrack t) => t.label), <String>[
      'clip.ja.srt',
    ]);
    expect(
      tracks.single.cues.first.startMs,
      closeTo(truth.first * 1000, 100),
      reason: '收进来的外挂轨按识别稿改写到了本片的时间轴',
    );
  });
}
