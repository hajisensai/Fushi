import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show videoImportCanImport;

/// 守卫「视频导入对话框：导入进行中（`importing`，来自 ImportFlowMixin）一律
/// 禁用所有动作按钮、不可重入」这一既有但此前无守卫的行为。
///
/// 这里走两层：
/// 1) **纯函数层**：[videoImportCanImport] 在 `busy=true` 时必返回 false，
///    确认按钮（`onPressed: _canImport ? _doImport : null`）因此被禁用。
/// 2) **源码扫描层**：`build()` 里取消 / 选视频 / 选字幕按钮的 `onPressed` 都以
///    `importing ? null :` 起手——锁住「busy 期间全禁用」。用源码扫描而非真跑
///    导入流程，是因为真流程会进 ffmpeg 抽帧子进程，无法在 widget 测试里
///    确定性地停在 busy 中段（会挂住 pump）。（选文件夹 / 选播放列表按钮已随
///    旧「对话框内建合集」入口删除，2026-08-19 用户指令。）
void main() {
  group('videoImportCanImport gates confirm button on busy', () {
    test('busy=true -> cannot import (confirm button disabled)', () {
      expect(
        videoImportCanImport(
          videoPath: '/v.mp4',
          subtitlePath: '/v.srt',
          busy: true,
        ),
        isFalse,
      );
    });

    test('busy=false with a video -> can import (confirm enabled)', () {
      expect(
        videoImportCanImport(
          videoPath: '/v.mp4',
          subtitlePath: null,
          busy: false,
        ),
        isTrue,
      );
    });
  });

  group('video_import_dialog.dart build() disables all buttons while busy', () {
    late String source;

    setUpAll(() {
      // 测试 cwd 是 fushi/；源码相对路径稳定。
      source = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
    });

    // 动作按钮在 busy 期都用 `importing ? null :` 起手禁用，避免重入导入。
    for (final String onTap in const <String>[
      '_pickVideo', // 选视频
      '_pickSubtitle', // 选外挂字幕
    ]) {
      test('button -> $onTap is gated on importing', () {
        expect(
          source.contains('importing ? null : $onTap'),
          isTrue,
          reason: '$onTap 按钮必须在 importing 期禁用（`importing ? null : $onTap`），'
              '否则导入中可重入触发并发导入',
        );
      });
    }

    test('cancel button is gated on importing', () {
      expect(
        source.contains(
            'onPressed: importing ? null : () => Navigator.pop(context)'),
        isTrue,
        reason: '取消按钮必须在 importing 期禁用，避免导入进行中关窗造成状态错乱',
      );
    });

    test('confirm button is gated on _canImport (which is false while busy)',
        () {
      expect(
        source.contains('onPressed: _canImport ? _doImport : null'),
        isTrue,
        reason: '确认按钮经 _canImport 门控；_canImport 在 busy 期返回 false',
      );
      // _canImport 确实把 busy 透传给纯判定函数。
      expect(
        source.contains('busy: importing,'),
        isTrue,
        reason: '_canImport 必须把 importing 喂给 videoImportCanImport',
      );
    });
  });
}
