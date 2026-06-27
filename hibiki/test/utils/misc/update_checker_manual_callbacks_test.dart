import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// TODO-898：手动检查「无可更新版本」判定的纯函数验证（必修2 endorse 的可测层）。
///
/// `_check` 在三处「无更新」早退触发 `onUpToDate`，它们的判定全由两个已
/// `@visibleForTesting` 的纯函数决定：
/// - `selectUpdateReleaseForCurrentPlatform`：空列表 / 无更新的 release → 返 null
///   （= `_check` :selection==null 早退 → onUpToDate）。
/// - `isUpdateVersionNewer`：远端不比本地新 → false（= `_check` 已是最新早退 → onUpToDate）。
///
/// 喂构造好的 release map 给这些纯函数断言「无更新」判定成立，不触 `_check` 的网络/
/// 子进程/path_provider IO（不拆其稳定路径）。回调的实际 wiring（三个
/// `onUpToDate?.call()` + `onError?.call(e)`）由源码守卫
/// `test/settings/manual_update_check_guard_test.dart` 静态断言。
void main() {
  final PlatformUpdater updater = updaterForCurrentPlatform();

  test('empty release list selects nothing (drives onUpToDate)', () async {
    final UpdateReleaseSelection? selection =
        await selectUpdateReleaseForCurrentPlatform(
      const <Map<String, dynamic>>[],
      currentVersion: '1.0.0',
      channel: UpdateChannel.stable,
      updater: updater,
    );
    expect(selection, isNull, reason: '无 release = 无可更新版本 → onUpToDate');
  });

  test('older stable release selects nothing (drives onUpToDate)', () async {
    final UpdateReleaseSelection? selection =
        await selectUpdateReleaseForCurrentPlatform(
      <Map<String, dynamic>>[buildStableReleaseFromTag('v0.0.1')],
      currentVersion: '9.9.9',
      channel: UpdateChannel.stable,
      updater: updater,
    );
    expect(selection, isNull, reason: '远端旧于本地 → 选不出 → onUpToDate');
  });

  test('isUpdateVersionNewer: equal/older stable is not newer', () {
    expect(
        isUpdateVersionNewer('1.2.3', '1.2.3', UpdateChannel.stable), isFalse,
        reason: '同版本 = 已是最新 → onUpToDate');
    expect(
        isUpdateVersionNewer('1.0.0', '1.2.3', UpdateChannel.stable), isFalse,
        reason: '远端更旧 = 已是最新 → onUpToDate');
  });

  test('isUpdateVersionNewer: a strictly newer stable is an update', () {
    expect(isUpdateVersionNewer('2.0.0', '1.2.3', UpdateChannel.stable), isTrue,
        reason: '远端更新 → 发现新版（走对话框/打开发布页，不触 onUpToDate）');
  });
}
