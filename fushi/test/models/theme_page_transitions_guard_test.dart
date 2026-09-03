// 页面转场矩阵守卫。
//
// 两件事各有代价，都必须钉住：
//
// 1. **Android 必须用 [FushiPredictiveBackPageTransitionsBuilder]**。换回 Flutter 自带的
//    预测性返回转场，就把「侧滑返回让整个 app 永久点不动」的缺陷放回来了（平台重发
//    起始事件 / 手势中途路由被 pop 都会让 navigator 的手势计数失配，而 `_ModalScope`
//    直接用它驱动 IgnorePointer）。根因与三条失配序列见
//    `test/utils/adaptive/predictive_back_gesture_accounting_test.dart`。
// 2. **六个平台必须逐个列出**。`PageTransitionsTheme.builders` 是全量替换而非合并：
//    漏掉的平台会回落到 `ZoomPageTransitionsBuilder`，iOS / macOS 因此静默丢掉
//    Cupertino 的边缘滑动返回——没有任何报错，只有用户发现「滑不回去了」。
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/predictive_back_page_transitions.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late ThemeNotifier notifier;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
  });

  tearDown(() async {
    notifier.dispose();
    await db.close();
  });

  test('Android 走 Fushi 自带手势记账的预测性返回转场', () {
    for (final ThemeData theme in <ThemeData>[
      notifier.theme,
      notifier.darkTheme,
    ]) {
      expect(
        theme.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<FushiPredictiveBackPageTransitionsBuilder>(),
      );
    }
  });

  test('六个平台全部显式配置，iOS/macOS 仍是 Cupertino 转场', () {
    final Map<TargetPlatform, PageTransitionsBuilder> builders =
        notifier.theme.pageTransitionsTheme.builders;
    for (final TargetPlatform platform in TargetPlatform.values) {
      expect(
        builders[platform],
        isNotNull,
        reason: '$platform 缺 builder 会静默回落到 ZoomPageTransitionsBuilder',
      );
    }
    expect(
      builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.macOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
  });
}
