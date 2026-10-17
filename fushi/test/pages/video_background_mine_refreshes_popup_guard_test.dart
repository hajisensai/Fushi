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
}
