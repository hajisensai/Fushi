import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3492：在线视频后台制卡时弹窗当场只拿到「已加入」（`MinePopupResult.queued`），
/// 卡真正进 Anki 是在后台任务落地那一刻。落地后必须经 [MinedStateSignal] 通知正在
/// 显示这个词的弹窗重问 Anki，把「已加入」换成真 ✓——否则同一个弹窗里点 ✓ / 从
/// 「高级制卡」回点都走不到覆盖，用户只能关掉弹窗重新查词。
///
/// 后台落卡在视频页私有方法 `_mineVideoCard` 里，要真跑需要播放器 + ffmpeg + Anki；
/// popup.js 侧的行为由 `test/utils/misc/popup_asset_behavior_test.js` 真跑钉住，这里
/// 只钉住宿主那一半接线没被拆掉。
void main() {
  test('后台落卡成功后通知弹窗重问这个词的制卡态', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final int background = source.indexOf('_trackBackgroundMine(');
    expect(background, greaterThan(0), reason: '后台落卡分支不见了');
    final int queuedReturn = source.indexOf(
      'return const MinePopupResult.queued();',
      background,
    );
    expect(queuedReturn, greaterThan(background));
    final String branch = source.substring(background, queuedReturn);
    expect(
      branch,
      contains("MinedStateSignal.instance.notifyWord(fields['expression']"),
      reason: '落地后要通知弹窗刷新，否则同一弹窗里的「已加入」永远不撤',
    );
    expect(
      branch,
      contains('landed.ankiConnect'),
      reason: '只有卡真的进了 Anki 才通知（暂存 / 失败不该把按钮画成 ✓）',
    );
  });

  // 排队覆盖（方案 B）的结算必须覆盖所有结局：`then(onSuccess, onError:)` 的 onError
  // 只接 job 自己的错误，onSuccess 里 `land(res)` 抛错时不会走到它——不包住就会让这个词
  // 的在途标记永远不清、排队的覆盖永远不结算。
  test('后台落卡：land 抛错也结算排队的覆盖，且按写入代号结算', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final int background = source.indexOf('_trackBackgroundMine(');
    final int queuedReturn = source.indexOf(
      'return const MinePopupResult.queued();',
      background,
    );
    final String branch = source.substring(background, queuedReturn);
    expect(
      RegExp(
        r'try \{\s*landed = land\(res\);\s*\} on Object catch \(error\) \{\s*'
        r'settleFailed\(error\);\s*rethrow;',
      ).hasMatch(branch),
      isTrue,
      reason: 'land(res) 抛错必须先结算排队的覆盖再抛出',
    );
    expect(
      RegExp(
        r'onError: \(Object error, StackTrace stack\) \{\s*settleFailed\(error\);',
      ).hasMatch(branch),
      isTrue,
      reason: 'job 自己抛错同样要结算',
    );
    expect(
      source,
      contains('_pendingOverwrites.addStarted(overwriteKey)'),
      reason: '每次后台写入领一个代号',
    );
    expect(branch, contains('overwriteAddId,'), reason: '结算时带上这次写入的代号');
  });

  test('迟到的覆盖请求按那次写入的结局回 settled，而不是一律说「还在写入」', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final int start = source.indexOf(
      'Future<QueuedOverwriteReply> _onQueueOverwriteImpl(',
    );
    expect(start, greaterThan(0));
    final String body = source.substring(
      start,
      source.indexOf('final MiningRequestOverrides? overrides', start),
    );
    expect(body, contains('_pendingOverwrites.lastLanded(key)'));
    expect(body, contains('QueuedOverwriteSettled.landed'));
    expect(body, contains('QueuedOverwriteSettled.failed'));
  });
}
