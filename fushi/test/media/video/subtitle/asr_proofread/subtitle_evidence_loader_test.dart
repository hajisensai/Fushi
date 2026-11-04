import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

const String _enSrt = '''1
00:00:01,000 --> 00:00:03,000
That song is really good.

2
00:00:05,000 --> 00:00:07,000
♪ I can hear your voice tonight
''';

/// 文件名标 en、内容是日文（字幕组标错轨）。
const String _mislabeledSrt = '''1
00:00:10,000 --> 00:00:12,000
今日はいい天気ですね、本当に
''';

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
    final String video = p.join(tmp.path, 'ep08.mkv');
    File(video).writeAsBytesSync(<int>[0, 1, 2, 3]);
    File(p.join(tmp.path, 'ep08.en.srt')).writeAsStringSync(_enSrt);
    File(p.join(tmp.path, 'ep08.ja.srt')).writeAsStringSync(_mislabeledSrt);
    File(p.join(tmp.path, 'ep08.fr.srt')).writeAsStringSync(_mislabeledSrt);
    final Directory docs = Directory(p.join(tmp.path, 'docs'))..createSync();
    final String imported = p.join(docs.path, 'abc123.srt');
    File(imported).writeAsStringSync(_mislabeledSrt);
    final String own = p.join(tmp.path, 'ep08.ja.srt');

    final SubtitleEvidenceCollector collector = SubtitleEvidenceCollector(
      extraSubtitleFiles: (String _) async => <String>[imported],
    );
    final List<SubtitleEvidenceTrack> tracks = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: const <SubtitleDraftCue>[],
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
    expect(byLabel['ep08.en.srt']!.synced, isFalse);

    // 来源身份：改了文件 → key 变。
    final String key1 = await collector.sourceKey(
      video,
      isOwnOutput: (String path) => p.equals(path, own),
    );
    File(p.join(tmp.path, 'ep08.en.srt')).writeAsStringSync('$_enSrt\n');
    final String key2 = await collector.sourceKey(
      video,
      isOwnOutput: (String path) => p.equals(path, own),
    );
    expect(key1, isNot(key2));
  });
}
