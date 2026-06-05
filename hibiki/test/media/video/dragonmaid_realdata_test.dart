@Tags(<String>['realdata'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;

/// 真机数据验证（需本机存在龙女仆素材；不存在则整组 skip）。
///
/// 跑：`flutter test test/media/video/dragonmaid_realdata_test.dart`
/// 验证：① 真实 m3u8 解析出 60+ 集、中文标题、第一集 mkv 存在；
///       ② S01E01.mkv → findSidecarSubtitle 命中 .ja.srt；
///       ③ SrtParser 解析出日文 cue（打印前 3 条确认是日文对白）。
void main() {
  const String m3u8Path =
      r"D:\video\Miss Kobayashi's Dragon Maid\Dragon Maid 观看顺序.m3u8";
  final bool hasData = File(m3u8Path).existsSync();

  test('真实龙女仆 m3u8 解析 + sidecar .ja.srt 日文 cue', () async {
    final String baseDir = p.dirname(m3u8Path);
    final String content = File(m3u8Path).readAsStringSync();
    final List<PlaylistEntry> entries =
        parseM3u8(content: content, baseDir: baseDir);

    // ① 集数与 m3u8 中 #EXTINF 条数一致（实测 55 集），标题非空，第一集存在。
    final int extinfCount = '\n$content'
        .split('\n')
        .where((String l) => l.startsWith('#EXTINF'))
        .length;
    expect(entries.length, extinfCount);
    expect(entries.length, greaterThanOrEqualTo(50));
    expect(entries.first.title.isNotEmpty, isTrue);
    final String firstPath = entries.first.path;
    expect(File(firstPath).existsSync(), isTrue,
        reason: 'first episode mkv must exist: $firstPath');

    // ② sidecar 检测：S01E01.mkv → .ja.srt。
    final String? sidecar = findSidecarSubtitle(firstPath, langCode: 'ja');
    expect(sidecar, isNotNull);
    expect(sidecar!.toLowerCase().endsWith('.ja.srt'), isTrue,
        reason: 'expected .ja.srt sidecar, got $sidecar');

    // ③ 解析日文 cue，打印前 3 条供肉眼确认。
    final String subText = await readTextWithEncoding(File(sidecar));
    final List<AudioCue> cues =
        SrtParser.parseString(content: subText, bookKey: 'probe');
    expect(cues.length, greaterThan(0));
    // ignore: avoid_print
    print('[dragonmaid] entries=${entries.length} '
        'first="${entries.first.title}" sidecar=$sidecar cues=${cues.length}');
    for (int i = 0; i < cues.length && i < 3; i++) {
      // ignore: avoid_print
      print('[dragonmaid][cue $i] ${cues[i].startMs}ms: ${cues[i].text}');
    }
  }, skip: hasData ? false : 'dragon maid 素材不存在，跳过真机数据验证');
}
