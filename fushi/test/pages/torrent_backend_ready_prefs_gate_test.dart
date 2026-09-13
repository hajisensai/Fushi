import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2376 批次：`torrentBackendReady` 自「下载界面多选批量操作」起被
/// `_planActions` 拉上了 **build 路径**——弹窗为每个任务条目算一次 `pauseCapable`。
///
/// 它内部读 `AppModel.qbConnectionConfig` → `prefsRepo`，而 `prefsRepo` 是
/// `_prefsRepo!`：prefs 还没接上时直接抛。build 里抛异常 = 整块界面炸掉
/// （实测 `anime_download_task_entry_test` 两条红在
/// `Null check operator used on a null value`）。
///
/// `AppModel.isPreferencesReady` 的存在就是因为确有那么一段 prefs 尚未装配，所以
/// 正确答案是**如实答「没就绪」**，不是让 `!` 抛出去。这条钉住它。
void main() {
  test('prefs 未接上时 torrentBackendReady 返回 false 而不是抛', () {
    final AppModel appModel = AppModel(testPlatformServices());
    expect(
      appModel.isPreferencesReady,
      isFalse,
      reason: '前置：这个 AppModel 故意没接 prefs（与下载弹窗那批用例同形）',
    );
    expect(
      () => torrentBackendReady(appModel),
      returnsNormally,
      reason: 'build 路径上的能力查询不得抛——抛了整块界面就没了',
    );
    expect(
      torrentBackendReady(appModel),
      isFalse,
      reason: 'prefs 没就绪 ⇒ 后端也谈不上就绪，如实答 false',
    );
  });
}
