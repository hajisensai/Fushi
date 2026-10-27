// 反馈 I1Bg6uMZ32：复习同步拉进别的设备的变更后，界面照常重读，但不再因此触发本机推送
// （以前拉入 → srsRevisionProvider +1 → SrsLocalPush 5 秒后又跑一轮同步，复习同步横幅再弹一次、
// 库页内容跟着上下挪）。推送只由本机写入触发。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_providers.dart';

void main() {
  group('SrsRevisionOrigin + listenSrsLocalWrites', () {
    late ProviderContainer c;
    late SrsRevisionOrigin origin;
    late int localWrites;
    late int uiRebuilds;
    late Provider<int> ui;

    setUp(() {
      origin = SrsRevisionOrigin();
      localWrites = 0;
      uiRebuilds = 0;
      final Provider<void> wiring = Provider<void>((Ref ref) {
        listenSrsLocalWrites(ref, origin, () => localWrites++);
      });
      // 一个照常订阅修订号的界面数据源（牌组列表等同形）。
      ui = Provider<int>((Ref ref) {
        uiRebuilds++;
        return ref.watch(srsRevisionProvider);
      });
      c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen<void>(wiring, (void a, void b) {}, fireImmediately: true);
      c.listen<int>(ui, (int? a, int b) {}, fireImmediately: true);
    });

    test('同步拉入：界面重读，不触发本机推送', () {
      final int before = c.read(srsRevisionProvider);
      origin.bumpPulled(c.read(srsRevisionProvider.notifier));
      expect(c.read(srsRevisionProvider), before + 1);
      expect(c.read(ui), before + 1);
      expect(uiRebuilds, 2, reason: '拉入的变更照样让界面重读');
      expect(localWrites, 0, reason: '拉进来的数据不该再推回去');
    });

    test('本机写入：触发推送；夹在两次拉入之间的本机写入也不漏', () {
      c.read(srsRevisionProvider.notifier).state++;
      expect(localWrites, 1);
      origin.bumpPulled(c.read(srsRevisionProvider.notifier));
      expect(localWrites, 1);
      c.read(srsRevisionProvider.notifier).state++;
      expect(localWrites, 2);
      origin.bumpPulled(c.read(srsRevisionProvider.notifier));
      origin.bumpPulled(c.read(srsRevisionProvider.notifier));
      expect(localWrites, 2);
    });
  });

  test('接线守卫：调度器的数据变动回调走「拉入」那一跳，推送只听本机写入', () {
    final String src = File(
      'lib/src/srs/srs_app_runtime.dart',
    ).readAsStringSync();
    expect(
      src,
      contains('onDataChanged: _bumpPulledRevision'),
      reason: '同步拉入的变更必须经 SrsRevisionOrigin.bumpPulled 递增',
    );
    expect(
      src,
      contains('listenSrsLocalWrites(ref, revisionOrigin, '),
      reason: '本机推送只能挂在 listenSrsLocalWrites 上',
    );
    expect(
      RegExp(r'ref\.listen<int>\(\s*srsRevisionProvider').hasMatch(src),
      isFalse,
      reason: '直接 listen 修订号会把同步拉入也当成本机写入',
    );
  });
}
