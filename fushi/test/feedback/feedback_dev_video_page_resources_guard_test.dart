// 处理台视频页的资源所有权（review of PR #2103）：
// 取视频要先在系统临时目录落一份 ≤ 50 MB 的文件，再开 media_kit 的 Player。原实现只在
// 一切顺利之后才把文件 / 播放器记进 State，`player.open` 抛错时临时目录与 Player 都没人
// 释放；open 成功但页面已卸载时只 dispose 了 Player、临时目录留在盘上。
//
// media_kit / libmpv 在测试宿主起不来（与 video_background_resume_guard_test 同一理由），
// 这页没法 headless 地真开一次播放器，所以在源码层钉住「交接之前归 _load 所有、交接失败
// 在 finally 里一并释放」这条契约。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String kDevVideoPagePath =
    'lib/src/pages/implementations/feedback/feedback_dev_video_page.dart';

void main() {
  final String src = File(
    kDevVideoPagePath,
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String load = maskComments(
    methodBody(src, 'Future<void> _load() async'),
  );

  test('临时目录与 Player 在交给 State 之前由 _load 持有，失败 / 已卸载都在 finally 释放', () {
    final int finallyAt = load.indexOf('} finally {');
    expect(
      finallyAt,
      greaterThanOrEqualTo(0),
      reason: '_load 必须用 finally 兜住临时目录与 Player 的释放',
    );
    final String tail = load.substring(finallyAt);
    expect(
      tail.contains('if (!adopted)'),
      isTrue,
      reason: '只有没交接给 State 时才在 finally 里释放，交接后归 dispose',
    );
    expect(
      tail.contains('player?.dispose()'),
      isTrue,
      reason: 'open 抛错 / 已卸载时 Player 要 dispose',
    );
    expect(
      tail.contains('_deleteTempDir(dir)'),
      isTrue,
      reason: 'open 抛错 / 已卸载时临时目录（≤ 50 MB）要删',
    );
  });

  test('交接标记只在 setState 把文件和 Player 记进 State 之后才置位', () {
    final int handOff = load.indexOf('_player = player;');
    final int adopted = load.indexOf('adopted = true;');
    expect(handOff, greaterThanOrEqualTo(0));
    expect(adopted, greaterThan(handOff), reason: '先置位再交接，中间一抛就两头都不释放');
    // 交接之前的每个 return 都落在 finally 的释放分支里：不许再出现「return 前手动只删
    // 一半」的旧写法。
    expect(
      load.contains('await player.dispose();'),
      isFalse,
      reason: 'Player 的释放统一走 finally，别在分支里各写一份',
    );
    expect(
      load.contains('await dir.delete('),
      isFalse,
      reason: '临时目录的释放统一走 finally，别在分支里各写一份',
    );
  });

  test('dispose 释放交接过来的 Player 与临时目录', () {
    final String dispose = maskComments(methodBody(src, 'void dispose()'));
    expect(dispose.contains('_player?.dispose()'), isTrue);
    expect(dispose.contains('_deleteTempDir(_file?.parent)'), isTrue);
  });
}
