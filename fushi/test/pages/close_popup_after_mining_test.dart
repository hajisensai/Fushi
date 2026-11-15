import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

/// 用户建议 q16Apecgbg：「制卡后关闭查词弹窗」。[closePopupAfterAcceptedMine] 是两条
/// 弹窗车道（阅读器 base_source_page / 视频等 DictionaryPageMixin）唯一的关窗判据。
void main() {
  group('closePopupAfterAcceptedMine', () {
    Future<int> run(MinePopupResult result, {required bool enabled}) async {
      int closed = 0;
      final Future<MinePopupResult> Function(Map<String, String>) wrapped =
          closePopupAfterAcceptedMine(
            (Map<String, String> f) async => result,
            enabled: () => enabled,
            closeAll: () => closed++,
          );
      final MinePopupResult got = await wrapped(<String, String>{});
      expect(identical(got, result), isTrue, reason: '结果必须原样回传给 popup.js');
      return closed;
    }

    test('开关打开：成功落卡关栈一次', () async {
      expect(
        await run(const MinePopupResult(ankiConnect: true), enabled: true),
        1,
      );
    });

    test('开关打开：进了待发队列也算收下', () async {
      expect(await run(const MinePopupResult.queued(), enabled: true), 1);
    });

    test('开关打开：失败 / 重复不关（用户还要看提示、可能重试）', () async {
      expect(await run(const MinePopupResult(), enabled: true), 0);
      expect(
        await run(const MinePopupResult(duplicate: true), enabled: true),
        0,
      );
    });

    test('开关关闭（默认）：成功也不关，与既有行为一致', () async {
      expect(
        await run(const MinePopupResult(ankiConnect: true), enabled: false),
        0,
      );
    });

    test('关栈发生在制卡落地之后，不提前（BUG-2627：提前关栈会清掉草稿）', () async {
      final Completer<MinePopupResult> landing = Completer<MinePopupResult>();
      int closed = 0;
      bool hostEntered = false;
      final Future<MinePopupResult> pending = closePopupAfterAcceptedMine(
        (Map<String, String> f) {
          hostEntered = true;
          return landing.future;
        },
        enabled: () => true,
        closeAll: () => closed++,
      )(<String, String>{});
      // BUG-2634：宿主的同步前缀在包装返回前已经跑完。
      expect(hostEntered, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(closed, 0);
      landing.complete(const MinePopupResult(ankiConnect: true));
      await pending;
      expect(closed, 1);
    });
  });

  test('两条弹窗车道的制卡回调都经 closePopupAfterAcceptedMine 接线', () {
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(
        RegExp(
          r'onMineEntry:\s*(cardCreationEnabled\s*\?\s*)?'
          r'closePopupAfterAcceptedMine\(',
        ).hasMatch(src),
        isTrue,
        reason: '$path 的 onMineEntry 必须包一层 closePopupAfterAcceptedMine',
      );
      expect(
        src.contains('ReaderFushiSource.instance.closePopupAfterMining'),
        isTrue,
        reason: '$path 必须读 close_popup_after_mining 偏好',
      );
    }
  });

  // 反馈 OeS0m8tLHc：视频页点「制卡」弹窗立刻关、视频立刻续播，卡在后台落地。
  group('视频车道：制卡不陪等（OeS0m8tLHc）', () {
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final String tracker = File(
      'lib/src/pages/implementations/video_fushi/mine_queue.part.dart',
    ).readAsStringSync();
    final String remote = File(
      'lib/src/pages/implementations/video_fushi/playback_remote.part.dart',
    ).readAsStringSync();

    test('mixin 经可覆写的 closePopupAfterMining 判是否关栈，视频页恒 true', () {
      expect(
        RegExp(
          r'closePopupAfterAcceptedMine\([\s\S]{0,240}?'
          r'enabled:\s*\(\)\s*=>\s*closePopupAfterMining,',
        ).hasMatch(mixin),
        isTrue,
        reason: 'mixin 的关栈判据必须走可覆写的 getter，视频页才能不看阅读器偏好',
      );
      expect(
        RegExp(
          r'@override\s+bool get closePopupAfterMining => true;',
        ).hasMatch(page),
        isTrue,
        reason: '视频页制卡后必须恒关弹窗（并经 _popNestedPopupAt 续播）',
      );
    });

    test('查词弹窗的新制卡不等落地：本地视频也走后台，只有遥控等结局', () {
      expect(
        mining.contains('bool awaitLocalLanding = false,'),
        isTrue,
        reason: '_onMineEntryImpl 默认（查词弹窗）不能等本地卡落地',
      );
      expect(
        mining.contains('awaitLocalLanding: awaitLocalLanding,'),
        isTrue,
        reason: '_onMineEntryImpl 必须把等不等交给 resolveVideoMineDispatch',
      );
      expect(
        remote.contains('_onMineEntryImpl(payload, awaitLocalLanding: true)'),
        isTrue,
        reason: '手机遥控制卡要把真实结局报回手机，仍等落地',
      );
      expect(
        mining.contains(
          'if (dispatch == VideoMineDispatch.awaitLanding) return land(await job);',
        ),
        isTrue,
      );
    });

    test('后台制卡失败：结果卡带「重试」（落地失败 / 抽取中止 / 抛错三条路）', () {
      expect(
        RegExp(
          r'expression: fields\[.expression.\],\s*retry: retry,',
        ).hasMatch(mining),
        isTrue,
        reason: '落地收尾 _landVideoMine 必须拿到 retry',
      );
      expect(
        RegExp(
          r'\}\),\s*retry: retry,\s*\);\s*return const MinePopupResult\.queued\(\);',
        ).hasMatch(mining),
        isTrue,
        reason: '后台任务抛错时 _trackBackgroundMine 也要能重试',
      );
      expect(
        mining.contains(
          'described.status == MineToastStatus.failed ? retry : null',
        ),
        isTrue,
        reason: '只有真失败挂重试，重复卡片不挂',
      );
      expect(
        mining.contains(
          '_showMineOsd(message, MineToastStatus.failed, null, retry);',
        ),
        isTrue,
        reason: '句子音频抽取中止也要能重试',
      );
      expect(
        tracker.contains(
          '_showMineOsd(message, MineToastStatus.failed, null, retry);',
        ),
        isTrue,
      );
      // 重试用点击当下冻结的那一帧，不借后来那次查词的对话框锁帧。
      expect(
        mining.contains('frozenCurrentFrame: currentFrameSnapshot,'),
        isTrue,
      );
      expect(
        mining.contains('t.video_mine_retry_cancelled_episode'),
        isTrue,
        reason: '换集后重试不能裁到新一集',
      );
    });
  });
}
