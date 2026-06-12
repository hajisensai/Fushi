import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-158 / BUG-216）：视频页系统栏沉浸**持续隐藏**。
///
/// 这与控制条 UI 锁（`_immersiveLocked`，见 video_immersive_lock_guard_test）是两回事：
/// 那个锁的是 media_kit 控制条是否弹出；这里管的是 Android 系统状态栏 / 导航栏是否
/// 隐藏（`SystemChrome.setEnabledSystemUIMode`）。
///
/// 根因：视频沉浸原先只在 [AppModel.openMedia] 打开媒体时一次性设
/// `immersiveSticky`（书 / 视频共用入口），`VideoHibikiPage` 全文 0 处自设系统栏模式，
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
    src = File('lib/src/pages/implementations/video_hibiki_page.dart')
        .readAsStringSync();
    appModelSrc = File('lib/src/models/app_model.dart').readAsStringSync();
  });

  test('① 视频页定义 _applyVideoImmersiveMode：移动端门控 + immersiveSticky', () {
    final int idx =
        src.indexOf('Future<void> _applyVideoImmersiveMode() async {');
    expect(idx, greaterThanOrEqualTo(0),
        reason: '视频页应自带 _applyVideoImmersiveMode（持有系统栏沉浸所有权）');
    final int end = src.indexOf('  }', idx);
    final String body = src.substring(idx, end);
    expect(
      body.contains('if (!isMobilePlatform) return;'),
      isTrue,
      reason: '沉浸模式必须 isMobilePlatform 门控（桌面无系统栏，no-op）',
    );
    expect(
      body.contains(
          'SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)'),
      isTrue,
      reason: '应设 immersiveSticky 隐藏系统栏（与既有基线一致，上划临时露栏后自动重隐）',
    );
  });

  test('② initState 显式调用 _applyVideoImmersiveMode（不再只靠 openMedia 一次性）', () {
    final int initIdx = src.indexOf('void initState() {');
    expect(initIdx, greaterThanOrEqualTo(0));
    final int initEnd = src.indexOf('  }', initIdx);
    final String initBody = src.substring(initIdx, initEnd);
    expect(
      initBody.contains('_applyVideoImmersiveMode()'),
      isTrue,
      reason: 'initState 必须显式自设沉浸，让所有权归视频页（而非依赖 openMedia 的一次性传递）',
    );
  });

  test('③ resumed 生命周期分支重申 _applyVideoImmersiveMode（后台返回不残留系统栏）', () {
    final int lifeIdx =
        src.indexOf('void didChangeAppLifecycleState(AppLifecycleState state)');
    expect(lifeIdx, greaterThanOrEqualTo(0));
    final int resumedIdx =
        src.indexOf('case AppLifecycleState.resumed:', lifeIdx);
    expect(resumedIdx, greaterThan(lifeIdx), reason: '应有 resumed 分支');
    // 下界：resumed 之后下一个 case（detached）或 switch 结束。
    final int nextCaseIdx =
        src.indexOf('case AppLifecycleState.detached:', resumedIdx);
    final String resumedBody = src.substring(resumedIdx, nextCaseIdx);
    expect(
      resumedBody.contains('_applyVideoImmersiveMode()'),
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
