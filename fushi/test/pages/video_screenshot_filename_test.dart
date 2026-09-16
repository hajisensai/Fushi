import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_screenshot_filename.dart';

import 'video_fushi_page_source_corpus.dart';

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

    test('带字幕截图是 PNG，扩展名跟着产物走', () {
      expect(
        videoScreenshotBaseName(
          sourcePathOrTitle: 'episode 01.mkv',
          positionMs: 90000,
          extension: 'png',
        ),
        'episode 01_00-01-30.png',
      );
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
    final String page = readVideoFushiSource();
    final int start =
        page.indexOf('Future<void> _saveScreenshot({bool withSubtitles');
    late final String body;

    setUpAll(() {
      expect(start, greaterThanOrEqualTo(0),
          reason: '两条截图快捷键必须仍汇到同一个 _saveScreenshot');
      final int end =
          page.indexOf('String _screenshotSourcePathOrTitle()', start);
      expect(end, greaterThan(start), reason: '_saveScreenshot 后续方法边界应稳定可截取');
      body = page.substring(start, end);
    });

    test('桌面保存对话框和移动分享临时文件都使用新截图 basename', () {
      expect(body.contains('videoScreenshotBaseName('), isTrue);
      expect(body.contains('uniqueVideoScreenshotBaseName('), isTrue);
      expect(body.contains('fileName: uniqueName'), isTrue,
          reason: '桌面 save dialog 默认名必须来自新命名 helper');
      expect(body.contains("mimeType: extension == 'png'"), isTrue,
          reason: '带字幕截图产物是 PNG，分享的 MIME 必须跟着扩展名走');
      expect(body.contains('subject: uniqueName'), isTrue,
          reason: '移动端分享 subject 必须与临时文件 basename 一致');
    });

    test('三种去向各有一条真实分支', () {
      expect(body.contains('VideoScreenshotDestination.clipboard'), isTrue);
      expect(body.contains('VideoScreenshotDestination.directory'), isTrue);
      expect(body.contains('VideoScreenshotDestination.ask'), isTrue);
      expect(body.contains('copyImageToClipboard('), isTrue,
          reason: '剪贴板分支必须真的调用写剪贴板入口，而不是只改个偏好');
      expect(body.contains('uniqueVideoScreenshotPath('), isTrue,
          reason: '直写目录分支必须走与对话框同一套重名计数后缀，否则连按会互相覆盖');
      expect(body.contains('t.video_screenshot_directory_unset'), isTrue,
          reason: '目录没设过必须提示并退回对话框，不能静默把文件丢到未知位置');
    });

    test('带字幕截图走 Dart 侧合成，不靠打开 libmpv 字幕', () {
      expect(body.contains('composeScreenshotWithOverlays('), isTrue);
      expect(body.contains('_clipExportSubtitleRenderer()'), isTrue,
          reason: '字幕外观必须复用片段导出那套渲染器，不另起一套');
      expect(body.contains('sub-visibility'), isFalse,
          reason: '字幕由 Flutter overlay 画，截图合成不得去动 libmpv 的字幕可见性');
    });

    test('两条快捷键分别接到同一执行体的两种参数', () {
      expect(page.contains('_saveScreenshot(withSubtitles: false)'), isTrue,
          reason: '不带字幕那条必须显式传 false，语义不靠默认值隐含');
      expect(page.contains('_saveScreenshot(withSubtitles: true)'), isTrue);
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
