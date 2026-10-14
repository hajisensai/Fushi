import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 设置页开关等处掉帧：根 build 在每次 AppModel 通知时都读 theme / darkTheme，
/// 以前每次都新建 ThemeData（内含新的 `WidgetStateProperty.resolveWith` 闭包，
/// 永远判不等），MaterialApp 便对任何偏好写入都播一遍 280ms 主题过渡。
/// 现在输入不变就必须返回**同一个实例**——MaterialApp 才会跳过过渡。
void main() {
  late FushiDatabase db;
  late ThemeNotifier notifier;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
    notifier.loadFromPrefsSnapshot(const <String, String>{});
  });

  tearDown(() async {
    notifier.dispose();
    await db.close();
  });

  test('输入不变时 theme / darkTheme 复用同一实例', () {
    expect(identical(notifier.theme, notifier.theme), isTrue);
    expect(identical(notifier.darkTheme, notifier.darkTheme), isTrue);
    expect(identical(notifier.theme, notifier.darkTheme), isFalse);
  });

  test('输入变化后重新构建并生效', () async {
    final ThemeData before = notifier.theme;
    await notifier.setEinkMode(true);
    final ThemeData after = notifier.theme;
    expect(identical(before, after), isFalse);
    // 墨水屏配色是纯黑白。
    expect(
      after.colorScheme.surface,
      notifier.buildColorScheme(Brightness.light).surface,
    );
    expect(identical(after, notifier.theme), isTrue);
  });

  test('平台覆盖是缓存键的一部分', () {
    final ThemeData host = notifier.theme;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final ThemeData ios = notifier.theme;
      expect(identical(host, ios), isFalse);
      expect(ios.platform, TargetPlatform.iOS);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(notifier.theme.platform, isNot(TargetPlatform.iOS));
  });
}
