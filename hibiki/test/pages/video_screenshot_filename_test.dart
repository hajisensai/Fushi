import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_screenshot_filename.dart';

void main() {
  group('videoScreenshotBaseName', () {
    test('源名、播放时间、当前时间一起入名，并保留 Unicode 标题', () {
      final String name = videoScreenshotBaseName(
        sourcePathOrTitle: r'D:\video\響け！ユーフォニアム 第1話?.mkv',
        positionMs: 65234,
        capturedAt: DateTime(2026, 6, 17, 23, 12, 5, 987),
      );

      expect(
        name,
        'hibiki_響け！ユーフォニアム 第1話_at_00h01m05s234_20260617_231205_987.jpg',
      );
    });

    test('同一视频同一播放位置的多次截图因当前时间不同而不重名', () {
      final String first = videoScreenshotBaseName(
        sourcePathOrTitle: '/videos/episode 01.mp4',
        positionMs: 90000,
        capturedAt: DateTime(2026, 6, 17, 23, 12, 5, 1),
      );
      final String second = videoScreenshotBaseName(
        sourcePathOrTitle: '/videos/episode 01.mp4',
        positionMs: 90000,
        capturedAt: DateTime(2026, 6, 17, 23, 12, 5, 2),
      );

      expect(first, isNot(second));
      expect(first, contains('episode 01_at_00h01m30s000'));
      expect(second, contains('episode 01_at_00h01m30s000'));
    });
  });

  group('uniqueVideoScreenshotBaseName', () {
    test('已存在同名时追加递增计数后缀', () {
      const String desired =
          'hibiki_episode 01_at_00h01m30s000_20260617_231205_001.jpg';
      final Set<String> existing = <String>{
        desired,
        'hibiki_episode 01_at_00h01m30s000_20260617_231205_001 (2).jpg',
      };

      expect(
        uniqueVideoScreenshotBaseName(
          desired,
          exists: existing.contains,
        ),
        'hibiki_episode 01_at_00h01m30s000_20260617_231205_001 (3).jpg',
      );
    });
  });

  group('_saveScreenshot 源码守卫', () {
    final String page = File(
      'lib/src/pages/implementations/video_hibiki_page.dart',
    ).readAsStringSync();
    final int start = page.indexOf('Future<void> _saveScreenshot()');
    late final String body;

    setUpAll(() {
      expect(start, greaterThanOrEqualTo(0),
          reason: '截图入口必须仍汇到 _saveScreenshot');
      final int end = page.indexOf('void _showSpeedMenu', start);
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
