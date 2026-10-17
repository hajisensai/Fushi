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
}
