import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_screenshot_filename.dart';

import 'video_hibiki_page_source_corpus.dart';

void main() {
  group('videoScreenshotBaseName', () {
    test(
        'TODO-564: 文件名 = 视频名 + 播放时刻(HH-MM-SS)，去掉 hibiki_ 前缀与毫秒/墙钟戳，保留 Unicode 标题',
        () {
      final String name = videoScreenshotBaseName(
        sourcePathOrTitle: r'D:\video\響け！ユーフォニアム 第1話?.mkv',
        positionMs: 65234,
      );

      // 旧名形如 hibiki_<标题>_at_00h01m05s234_20260617_231205_987.jpg，
      // 新名只保留语义化的「视频名 + 播放时刻」。
      expect(name, '響け！ユーフォニアム 第1話_00-01-05.jpg');
    });

    test('TODO-564: 文件名不再含旧前缀/毫秒/墙钟时间戳段', () {
      final String name = videoScreenshotBaseName(
        sourcePathOrTitle: '/videos/episode 01.mp4',
        positionMs: 90000,
      );

      expect(name, 'episode 01_00-01-30.jpg');
      expect(name.startsWith('hibiki_'), isFalse);
      expect(name.contains('_at_'), isFalse);
      // 无 9 位以上的连续墙钟时间戳数字串（旧的 YYYYMMDD/毫秒）。
      expect(RegExp(r'\d{8,}').hasMatch(name), isFalse);
    });

    test('TODO-564: 同一视频同一播放秒得到同名，唯一性交给去重层兜底', () {
      final String first = videoScreenshotBaseName(
        sourcePathOrTitle: '/videos/episode 01.mp4',
        positionMs: 90000,
      );
      final String second = videoScreenshotBaseName(
        sourcePathOrTitle: '/videos/episode 01.mp4',
        positionMs: 90120,
      );

      // 同一秒（90000ms 与 90120ms 都落在 00:01:30）→ 名字相同，
      // 由 uniqueVideoScreenshotBaseName 的 (n) 后缀保证不撞名。
      expect(first, second);
      expect(first, 'episode 01_00-01-30.jpg');
    });
  });

  group('uniqueVideoScreenshotBaseName', () {
    test('已存在同名时追加递增计数后缀（同一视频同一播放秒连点截图靠这层兜唯一）', () {
      const String desired = 'episode 01_00-01-30.jpg';
      final Set<String> existing = <String>{
        desired,
        'episode 01_00-01-30 (2).jpg',
      };

      expect(
        uniqueVideoScreenshotBaseName(
          desired,
          exists: existing.contains,
        ),
        'episode 01_00-01-30 (3).jpg',
      );
    });
  });

  group('_saveScreenshot 源码守卫', () {
    final String page = readVideoHibikiSource();
    final int start = page.indexOf('Future<void> _saveScreenshot()');
    late final String body;

    setUpAll(() {
      expect(start, greaterThanOrEqualTo(0),
          reason: '截图入口必须仍汇到 _saveScreenshot');
      final int end =
          page.indexOf('String _screenshotSourcePathOrTitle()', start);
      expect(end, greaterThan(start), reason: '_saveScreenshot 后续方法边界应稳定可截取');
      body = page.substring(start, end);
    });

    test('桌面保存对话框和移动分享临时文件都使用新截图 basename', () {
      expect(body.contains('videoScreenshotBaseName('), isTrue);
      expect(body.contains('uniqueVideoScreenshotBaseName('), isTrue);
      expect(body.contains('fileName: screenshotName'), isTrue,
          reason: '桌面 save dialog 默认名必须来自新命名 helper');
      expect(
          body.contains('XFile(tmp.path, mimeType: \'image/jpeg\')'), isTrue);
      expect(body.contains('subject: screenshotName'), isTrue,
          reason: '移动端分享 subject 必须与临时文件 basename 一致');
    });

    test('旧的固定 hibiki_视频名.jpg 默认名不再保留', () {
      expect(
        body.contains('hibiki_\${p.basenameWithoutExtension'),
        isFalse,
        reason: '旧命名同一视频多次截图默认同名，会覆盖/混淆',
      );
    });
  });
}
