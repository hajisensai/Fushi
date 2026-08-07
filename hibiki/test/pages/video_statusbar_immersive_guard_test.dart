import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 源码守卫（TODO-158 / BUG-219）：视频页系统栏沉浸**持续隐藏**。
///
/// 这与控制条 UI 锁（`_immersiveLocked`，见 video_immersive_lock_guard_test）是两回事：
/// 那个锁的是 media_kit 控制条是否弹出；这里管的是 Android 系统状态栏 / 导航栏是否
/// 隐藏（`SystemChrome.setEnabledSystemUIMode`）。
///
/// 根因：视频沉浸原先只在 [AppModel.openMedia] 打开媒体时一次性设
/// `immersiveSticky`（书 / 视频共用入口），`VideoFushiPage` 全文 0 处自设系统栏模式，
/// 也从不重申 → 后台返回 / 通知栏交互 / 多任务切回后系统栏残留显示。
///
/// 修复：把视频沉浸所有权移到本页，且**持续重申**——
/// ① initState 显式调 [_applyVideoImmersiveMode]（不再只靠 openMedia 的一次性）；
/// ② didChangeAppLifecycleState 的 resumed 分支重申（回前台后系统栏被恢复，主动重隐）；
/// ③ 方法 `isMobilePlatform` 门控 + 设 `SystemUiMode.immersiveSticky`，桌面 no-op；
/// ④ 严格限本页：不动 openMedia（书走 reader 自设 edgeToEdge、首页走
///    setHomeShellSystemUiMode），退出由 [AppModel.closeMedia] 还原。
///
/// 用静态扫描守卫：media_kit 跑不了 headless，系统栏模式切换 / 生命周期回前台都无法
/// 在 widget 测试里真实驱动（与 _lockLandscapeForVideo / _restoreOrientationOnExit 同
/// 范式）。
void main() {
  late String src;
  late String appModelSrc;

  setUpAll(() {
    src = File('lib/src/pages/implementations/video_fushi_page.dart')
        .readAsStringSync();
    appModelSrc = File('lib/src/models/app_model.dart').readAsStringSync();
  });

  test('① 视频页定义 _applyVideoImmersiveMode：移动端门控 + immersiveSticky', () {
    final String body =
        methodBody(src, 'Future<void> _applyVideoImmersiveMode() async {');
    expect(
      containsCodeLine(body, 'if (!isMobilePlatform) return;'),
      isTrue,
      reason: '沉浸模式必须 isMobilePlatform 门控（桌面无系统栏，no-op）',
    );
    expect(
      containsCodeLine(body,
          'SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)'),
      isTrue,
      reason: '应设 immersiveSticky 隐藏系统栏（与既有基线一致，上划临时露栏后自动重隐）',
    );
  });

  test('② initState 显式调用 _applyVideoImmersiveMode（不再只靠 openMedia 一次性）', () {
    // 旧写法用 `src.indexOf('  }', initIdx)` 当右边界：initState 里一旦出现嵌套块
    // （`if (Platform.isWindows) { ... }` 的收尾行 `    }` 里就含 `'  }'`），窗口
    // 会被截断在那儿，后面的接线全部看不见 → 守卫塌掉误报。改花括号配对。
    final String initBody = methodBody(src, 'void initState() {');
    expect(
      containsCodeLine(initBody, '_applyVideoImmersiveMode()'),
      isTrue,
      reason: 'initState 必须显式自设沉浸，让所有权归视频页（而非依赖 openMedia 的一次性传递）',
    );
  });

  test('③ resumed 生命周期分支重申 _applyVideoImmersiveMode（后台返回不残留系统栏）', () {
    final int lifeIdx =
        src.indexOf('void didChangeAppLifecycleState(AppLifecycleState state)');
    expect(lifeIdx, greaterThanOrEqualTo(0));
    // 右边界取 resumed 之后的下一个同级标签；找不到时退到文件末尾，不会像裸
    // indexOf 返回 -1 那样让 substring 抛 RangeError。
    final String resumedBody = switchCaseBody(
      src,
      'case AppLifecycleState.resumed:',
      searchFrom: lifeIdx,
      nextLabels: const <String>[
        'case AppLifecycleState.detached:',
        'case AppLifecycleState.inactive:',
        'case AppLifecycleState.paused:',
        'case AppLifecycleState.hidden:',
      ],
    );
    expect(
      containsCodeLine(resumedBody, '_applyVideoImmersiveMode()'),
      isTrue,
      reason: 'resumed 必须重申沉浸：回前台后 Android 恢复系统栏，不重申就「隐了又冒出来」',
    );
  });

  test('④ 严格限视频页：openMedia 仍是共用入口的一次性基线，未被本修复污染', () {
    // openMedia 对所有媒体设 immersiveSticky 是既有基线（书随后被 reader 覆盖成
    // edgeToEdge），本修复不动它——只在视频页加持续重申。守卫钉住 openMedia 仍只
    // 这一处系统栏设置，避免误把视频专属逻辑塞进共用入口。
    expect(
      appModelSrc.contains(
          'SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)'),
      isTrue,
      reason: 'openMedia 的 immersiveSticky 基线应保留（书/视频共用打开入口）',
    );
    expect(
      'SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)'
          .allMatches(appModelSrc)
          .length,
      1,
      reason: 'app_model 里系统栏沉浸只应有 openMedia 一处，视频专属重申不得下沉到共用入口',
    );
  });
}
