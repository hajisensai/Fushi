import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('TODO-434 远端视频片段导出守卫', () {
    test('远端直连流只提示先下载，不进入片段导出状态', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(idx, greaterThanOrEqualTo(0),
          reason: '片段导出入口应统一走 _toggleClipExport');
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      expect(end, greaterThan(idx),
          reason: '_toggleClipExport 应位于截图 helper 之前，便于同组维护');
      final String body = page.substring(idx, end);

      final int remoteCheck = body.indexOf('if (_isRemote');
      final int remoteMessage =
          body.indexOf('t.video_clip_export_remote_download_required');
      final int markingWrite = body.indexOf('_clipExportMarking = true');
      final int exportingWrite = body.indexOf('_clipExporting = true');

      expect(remoteCheck, greaterThanOrEqualTo(0), reason: '远端视频没有本地源文件，必须先门控');
      expect(remoteMessage, greaterThan(remoteCheck),
          reason: '远端路径必须给出“先下载到本机”提示');
      expect(markingWrite, greaterThan(remoteMessage),
          reason: '远端提示必须早于进入 marking 状态');
      expect(exportingWrite, greaterThan(remoteMessage),
          reason: '远端提示必须早于进入 exporting 状态');
    });

    test('切源会在 ffmpeg 启动前取消片段导出状态', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      final String body = page.substring(idx, end);

      final int outputPathAwait =
          body.indexOf('final String outputPath = await _clipExportOutputPath');
      final int preStartGuard = body.indexOf(
        'generation != _clipExportGeneration || _currentVideoPath != startPath',
        outputPathAwait,
      );
      final int exportingWrite =
          body.indexOf('_clipExporting = true', outputPathAwait);
      final int exportCall =
          body.indexOf('exportVideoClipViaFfmpeg', outputPathAwait);

      expect(outputPathAwait, greaterThanOrEqualTo(0));
      expect(preStartGuard, greaterThan(outputPathAwait));
      expect(preStartGuard, lessThan(exportingWrite));
      expect(preStartGuard, lessThan(exportCall));
    });

    test('页面文案保持源片段导出语义', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      final String body = page.substring(idx, end);
      final String formerPixelCaptureTerm =
          String.fromCharCodes(<int>[0x5f55, 0x5c4f]);
      final String formerEnglishTerm =
          <String>['screen', 'recording'].join(' ');
      expect(body.contains(formerPixelCaptureTerm), isFalse);
      expect(body.contains(formerEnglishTerm), isFalse);
    });
  });
}
