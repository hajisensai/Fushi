import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2010 守卫：[ThemeNotifier.refreshSystemPalette] 必须**幂等**——系统色没变
/// 就不许广播。
///
/// 为什么这条值得一个测试：这个方法挂在 `AppLifecycleState.resumed` 上，而桌面端
/// 每次窗口激活都会走一遍 resumed。无条件 `notifyListeners()` ＝ 「每把 Fushi 拉
/// 到前台一次，就让整棵 widget 树重建一次」。重建本身无害，但它是「一拉到前台就
/// 闪」的放大器：任何把 `FutureBuilder.future` 写在 `build()` 里、且判
/// `connectionState` 的页面都会被它打回加载态（见
/// `test/pages/detail_future_identity_test.dart`）。
///
/// 系统调色板本就极少变，代价几乎为零。
///
/// 变异有效性（已实测）：删掉 `if (unchanged) return;` 这条判据，「同色重复刷新」
/// 用例立刻红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('io.material.plugins/dynamic_color');

  TextTheme textThemeBuilder() => const TextTheme();

  late FushiDatabase db;
  late ThemeNotifier notifier;
  late int notifications;
  int? accentArgb;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, textThemeBuilder);
    notifications = 0;
    notifier.addListener(() => notifications++);
    // 桌面端形状：没有完整 CorePalette（那是 Android 独有），只有一个强调色。
    accentArgb = 0xFF112233;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getAccentColor') return accentArgb;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
  });

  test('默认主题就是 system-theme（本守卫的前提）', () {
    expect(notifier.appThemeKey, 'system-theme');
  });

  test('首次取到强调色 → 广播一次', () async {
    await notifier.refreshSystemPalette();
    expect(notifications, 1);
    expect(notifier.systemPrimaryColor, const Color(0xFF112233));
  });

  test('同色重复刷新 → 不再广播（每次拉到前台都会走这里）', () async {
    await notifier.refreshSystemPalette();
    expect(notifications, 1, reason: '首次是真变化，应当广播');

    // 模拟「用户把 Fushi 切走又切回来」若干次：系统色一动没动。
    await notifier.refreshSystemPalette();
    await notifier.refreshSystemPalette();
    await notifier.refreshSystemPalette();

    expect(
      notifications,
      1,
      reason: '系统色没变却广播 = 每次拉到前台就把整棵树重建一遍',
    );
  });

  test('强调色真的变了 → 照常广播', () async {
    await notifier.refreshSystemPalette();
    expect(notifications, 1);

    accentArgb = 0xFF445566;
    await notifier.refreshSystemPalette();

    expect(notifications, 2, reason: '幂等判据不许把真实变更也吞掉');
    expect(notifier.systemPrimaryColor, const Color(0xFF445566));
  });
}
