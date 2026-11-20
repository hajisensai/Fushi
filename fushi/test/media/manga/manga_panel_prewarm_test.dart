import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_panel_prewarm.dart';

/// manga-21 复核：分镜检测器内部串行，每翻一页都丢一个预热进去的话，快速翻页 /
/// 跳页会排起一串翻过去的页的推理，按键时当前页排在它们后面。
void main() {
  Future<void> pump() async {
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'rapid turns warm only the in-flight target and then the latest',
    () async {
      int current = 0;
      final List<int> warmed = <int>[];
      final List<Completer<void>> gates = <Completer<void>>[];
      final MangaPanelPrewarmer<int> prewarmer = MangaPanelPrewarmer<int>(
        target: () => current,
        warm: (int target) {
          warmed.add(target);
          final Completer<void> gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );
      prewarmer.request();
      for (int spread = 1; spread <= 9; spread++) {
        current = spread;
        prewarmer.request();
      }
      await pump();
      expect(warmed, <int>[0], reason: '在飞期间的请求不排队');
      gates[0].complete();
      await pump();
      expect(warmed, <int>[0, 9], reason: '结束后直接追最新目标，中间的跨页不检测');
      gates[1].complete();
      await pump();
      expect(warmed, <int>[0, 9], reason: '目标没变就停');
      expect(prewarmer.running, isFalse);
    },
  );

  test(
    'a closed gate warms nothing; a failure does not stop later warms',
    () async {
      int? current;
      final List<int> warmed = <int>[];
      final List<Object> errors = <Object>[];
      final MangaPanelPrewarmer<int> prewarmer = MangaPanelPrewarmer<int>(
        target: () => current,
        warm: (int target) async {
          warmed.add(target);
          if (target == 1) throw StateError('io');
        },
        onError: (Object error, StackTrace _) => errors.add(error),
      );
      prewarmer.request();
      await pump();
      expect(warmed, isEmpty);
      current = 1;
      prewarmer.request();
      await pump();
      expect(errors, hasLength(1));
      expect(prewarmer.running, isFalse);
      current = 2;
      prewarmer.request();
      await pump();
      expect(warmed, <int>[1, 2]);
    },
  );

  test('dispose stops chasing after the in-flight warm', () async {
    int current = 0;
    final List<int> warmed = <int>[];
    final Completer<void> gate = Completer<void>();
    final MangaPanelPrewarmer<int> prewarmer = MangaPanelPrewarmer<int>(
      target: () => current,
      warm: (int target) {
        warmed.add(target);
        return target == 0 ? gate.future : Future<void>.value();
      },
    );
    prewarmer.request();
    current = 5;
    prewarmer.dispose();
    gate.complete();
    await pump();
    prewarmer.request();
    await pump();
    expect(warmed, <int>[0]);
  });
}
