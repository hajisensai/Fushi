import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// BUG-1106 的防线延伸：**凡是起真 app 又靠 Tab 遍历驱动的集成测试，
/// 都必须先打开实验「键盘/手柄焦点导航」开关**，否则在全新 profile 上必红。
///
/// 根因：`lib/src/shortcuts/global_navigation.dart` 的 `wrapWithGlobalNavigation`
/// 在该开关关闭时把裸 Tab / Shift+Tab 中和成 `DoNothingIntent`（用户裁定的
/// 正确默认——没开焦点导航时按 Tab 不该有动作，TODO-112），停掉 `WidgetsApp`
/// 内建的焦点遍历。而 `tool/run_windows_itest.ps1` 每次用全新 GUID 隔离根跑，
/// 偏好恒为默认值，于是 `FocusDriver` 的合成 Tab 一步都走不动，表现是
/// 「reached 1 targets」而非几十个。BUG-1106 就是这么红了六周多没人发现。
///
/// 靠「注释里写一句别忘了开开关」当唯一防线已经被证伪过一次（该注释存在期间
/// 照样漏了一批文件），所以这里用源码扫描把契约钉死：用了遍历 API 就必须显式开开关。
///
/// 判据三条同时成立才算违规：
///   1. 用了 [FocusDriver] 里真靠 Tab 键的遍历 API（`reachAll` / `focusUntil` /
///      `focusWidget`）；像直接 `requestFocus` 那类不走 Tab 的用法不受开关影响；
///   2. 起了真 app（`app.main()`）——全局 Tab 中和层只挂在 `main.dart` 的
///      `wrapWithGlobalNavigation` 里，自己 `pumpWidget` 裸 `MaterialApp` 的用例
///      （如 `reader_settings_layout_reachability_test.dart`）根本没那层，Tab 原生可用，
///      硬塞开关只会制造噪声；
///   3. 全文没有打开开关的调用（`enableFocusNavigation(` 或直接
///      `setExperimentalFocusNavigationEnabled`）。
void main() {
  /// FocusDriver 里真正依赖 Tab 键遍历的入口。
  const List<String> traversalApis = <String>[
    'reachAll(',
    'focusUntil(',
    'focusWidget(',
  ];

  /// 打开开关的两种合法写法：共享 helper，或直接调 AppModel setter。
  const String helperCall = 'enableFocusNavigation(';
  const String rawSetter = 'setExperimentalFocusNavigationEnabled';

  /// 真 app 启动标志：只有它才会挂上中和 Tab 的全局 shortcuts 层。
  const String bootsRealApp = 'app.main()';

  test('every Tab-traversing integration test enables focus navigation first',
      () {
    final Directory dir = Directory('integration_test');
    expect(dir.existsSync(), isTrue,
        reason: 'run from the fushi/ package root (cwd=fushi/)');

    final List<String> offenders = <String>[];
    int inScope = 0;

    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String rel = entity.path.replaceAll('\\', '/');
      // helpers/ 是驱动器本体与夹具，不是用例。
      if (rel.contains('/helpers/')) continue;

      // 只看代码：注释里提一嘴 `app.main()` 不算起真 app，注释里写
      // enableFocusNavigation 也不算真开了开关。
      final String source = _stripComments(entity.readAsStringSync());
      if (!traversalApis.any((String api) => source.contains(api))) continue;
      if (!source.contains(bootsRealApp)) continue;
      inScope++;
      if (source.contains(helperCall) || source.contains(rawSetter)) continue;
      offenders.add(rel);
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些集成测试起真 app 并用 Tab 遍历，却没先打开实验焦点导航开关，'
          '在全新 profile 上必红（BUG-1106 同根因）。修法：第一次遍历之前调 '
          '`await enableFocusNavigation(tester);`（integration_test/helpers/'
          'focus_driver.dart）。违规文件：\n${offenders.join('\n')}',
    );

    // 防守卫自己被重构掉底：若 app.main() / 遍历 API 改名，扫描集会静默清空。
    expect(inScope, greaterThanOrEqualTo(25),
        reason: '扫描集只剩 $inScope 个文件，远低于当前实际规模——很可能是 '
            'app.main() 或 FocusDriver 遍历 API 改名后守卫认不出来了，先修判据再跑。');
  });

  test('the shared enabler helper really flips the AppModel preference', () {
    final File helper = File('integration_test/helpers/focus_driver.dart');
    expect(helper.existsSync(), isTrue);
    final String source = _stripComments(helper.readAsStringSync());
    expect(source.contains('Future<AppModel> enableFocusNavigation('), isTrue,
        reason: 'enableFocusNavigation 是上面那条契约的唯一共享入口，不得删除/改名');
    expect(
        source.contains('setExperimentalFocusNavigationEnabled(true)'), isTrue,
        reason: 'helper 必须真写开关，否则守卫只是在数字符串');
  });
}

/// 丢掉行注释（`//` / `///`），使扫描只针对真代码。字符串里的 `//`（如 URL）
/// 会跟着被截掉，对本守卫的 token 扫描无影响。
String _stripComments(String source) => maskComments(source);
