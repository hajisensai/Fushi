import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_video_diag_log.dart';
import 'package:fushi/src/utils/misc/debug_log_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 反馈 MReV894ote：用户报视频平移镜头掉帧，开发者在反馈里却看不到任何视频性能
/// 数据——上屏 / 丢帧 / 帧耗时只写在 video_diag_log.txt，反馈日志汇总点只拼错误
/// 日志、调试日志、游戏内查词与数据位置。现在随「调试日志」开关摘白名单类别进来；
/// 带查询词的 lookup / popup 行与 libmpv verbose 转写行（路径、URL）不得进来。
void main() {
  const String raw =
      '2026-11-26 19:15:31.671161 [  4463.570][info][video] page open platform=windows\n'
      '2026-11-26 19:15:32.673112 [  4464.572][warn][frame] video-page frames=75 fps=74.9 jank=2 severe=1\n'
      '2026-11-26 19:15:33.134608 [  4465.079][v][mpv/stats] playing=true window=1118ms late=+0 vo-drop=+0\n'
      '2026-11-26 19:15:33.137116 [  4465.082][v][mpv/stats] present window=1118ms published=24 shown=21 lost=3\n'
      '2026-11-26 19:15:34.000000 [  4466.000][v][lookup] begin term=秘密 warm=hit\n'
      '2026-11-26 19:15:34.100000 [  4466.100][v][popup] renderPopup term=秘密\n'
      '2026-11-26 19:15:35.413553 [  4467.313][error][mpv/libmpv_render/dxva2-egl] Failed to create EGL surface\n'
      '2026-11-26 19:15:35.500000 [  4467.400][v][mpv/cplayer] Playing: C:/Videos/私人片名.mkv\n'
      '2026-11-26 19:15:35.600000 [  4467.500][warn][mpv/stream] open https://emby.example/v?api_key=SEKRET failed\n'
      'garbage line without header\n';

  group('videoDiagFeedbackLines', () {
    test('keeps performance categories and mpv warnings, drops the rest', () {
      final List<String> lines = videoDiagFeedbackLines(raw);
      final String joined = lines.join('\n');
      expect(joined, contains('[video] page open'));
      expect(joined, contains('[frame] video-page frames=75'));
      expect(
        joined,
        contains('present window=1118ms published=24 shown=21 lost=3'),
      );
      expect(joined, contains('late=+0 vo-drop=+0'));
      expect(joined, contains('Failed to create EGL surface'));
      expect(joined, isNot(contains('秘密')));
      expect(joined, isNot(contains('私人片名')));
      expect(joined, isNot(contains('garbage')));
      // warn 级 mpv 转写行收进来，但令牌要抹掉。
      expect(joined, contains('api_key=[redacted]'));
      expect(joined, isNot(contains('SEKRET')));
      expect(lines, hasLength(6));
    });

    test('keeps only the most recent maxLines', () {
      final String many = List<String>.generate(
        10,
        (int i) =>
            '2026-11-26 19:00:0$i.000000 [  ${100 + i}.000][v][mpv/stats] n=$i',
      ).join('\n');
      final List<String> lines = videoDiagFeedbackLines(many, maxLines: 3);
      expect(lines, hasLength(3));
      expect(lines.first, endsWith('n=7'));
      expect(lines.last, endsWith('n=9'));
    });
  });

  group('readVideoDiagFeedbackLines', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_vdiag_fb_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('missing file yields nothing', () {
      expect(
        readVideoDiagFeedbackLines(file: File('${tmp.path}/none.txt')),
        isEmpty,
      );
    });

    test('reads only the tail and drops the cut first line', () {
      final File f = File('${tmp.path}/${VideoDiagLog.fileName}')
        ..writeAsStringSync(
          '${'x' * 400}\n'
          '2026-11-26 19:15:33.137116 [  4465.082][v][mpv/stats] present lost=0\n',
        );
      final List<String> lines = readVideoDiagFeedbackLines(
        file: f,
        tailBytes: 120,
      );
      expect(lines, hasLength(1));
      expect(lines.single, endsWith('present lost=0'));
    });
  });

  group('collectFeedbackLogText video section', () {
    late Directory tmp;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmp = Directory.systemTemp.createTempSync('fushi_vdiag_collect_');
      await ErrorLogService.instance.init(directoryOverride: tmp);
      await DebugLogService.instance.init();
      VideoDiagLog.instance.resetForTesting();
      await VideoDiagLog.instance.init(directoryOverride: tmp);
      File('${tmp.path}/${VideoDiagLog.fileName}').writeAsStringSync(raw);
    });

    tearDown(() async {
      VideoDiagLog.instance.resetForTesting();
      await ErrorLogService.instance.flush();
      tmp.deleteSync(recursive: true);
    });

    test('feedback with debug log carries the video section before data '
        'location', () {
      final String log = collectFeedbackLogText(includeDebugLog: true);
      expect(log, contains('==== video diagnostics ===='));
      expect(log, contains('video-diagnostics-enabled: false'));
      expect(log, contains('published=24 shown=21 lost=3'));
      expect(log, isNot(contains('秘密')));
      final int data = log.indexOf('==== data location diagnostics ====');
      if (data >= 0) {
        expect(log.indexOf('==== video diagnostics ===='), lessThan(data));
      }
    });

    test('crash report (no debug log) never carries it', () {
      final String log = collectFeedbackLogText(includeDebugLog: false);
      expect(log, isNot(contains('==== video diagnostics ====')));
      expect(log, isNot(contains('present window')));
    });
  });
}
