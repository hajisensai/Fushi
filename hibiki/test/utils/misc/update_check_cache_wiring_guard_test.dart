import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1024 / BUG-479 源码守卫：缓存优先 + 后台静默刷新的接线不变量。
///
/// 缓存写入发生在 `_check` 拿到合法 tag 之后（需 BuildContext + PlatformUpdater +
/// path_provider IO，不宜在纯 widget 测里跑全程，与既有 `manual_update_check_guard`
/// 同范式），故用静态守卫固化接线，撤回任意一条都会红：
/// - `_check` 在解析出 tag 后、在「是否更新」判断之前，把结果写回缓存（`cacheWriter`）；
/// - `scheduleCheck` / `_check` 暴露默认 null 的 `cacheReader` / `cacheWriter`（旧调用零变化）；
/// - 启动期自动检查（home_page）与手动检查（settings）都传 `cacheWriter`，保持缓存常新；
/// - 手动检查先读缓存乐观反馈（`cachedEntryForChannel` + `isUpdateVersionNewer` →
///   `update_cached_newer` / `update_cached_up_to_date`），无缓存才退回 `update_checking_now`；
/// - 缓存落 `preferences` 表单 key（不动 schema），由 PreferencesRepository 读写。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('_check writes the cache after resolving the latest tag', () {
    final String src = read('lib/src/utils/misc/update_checker_release.dart');
    // cacheWriter 参数存在且默认 null（向后兼容）。
    expect(src, contains('UpdateCheckCacheWriter? cacheWriter,'));
    // 写缓存发生在「拿到 tag」之后、「是否更新」判断之前。
    final int writeIdx = src.indexOf('await cacheWriter(entry);');
    expect(writeIdx, isNonNegative, reason: '_check 必须写回缓存');
    final int newerIdx =
        src.indexOf('if (!isUpdateVersionNewer(tagName, currentVersion');
    expect(newerIdx, isNonNegative);
    expect(writeIdx, lessThan(newerIdx),
        reason: '写缓存须在「是否更新」判断之前，覆盖 up-to-date 与 newer 两路');
    // 缓存条目带本通道 + tag + html + 时间戳。
    expect(src, contains('latestTag: tagName,'));
    expect(src, contains('channel: channel,'));
    expect(src, contains('lastCheckEpochMs:'));
    // 写缓存失败不得影响检查流程（吞 + 记日志）。
    expect(
        src, contains("debugPrint('[UpdateChecker] write update cache failed"));
  });

  test('scheduleCheck threads cacheWriter into _check', () {
    final String src = read('lib/src/utils/misc/update_checker_release.dart');
    expect(src, contains('cacheWriter: cacheWriter,'),
        reason: 'scheduleCheck 须把 cacheWriter 透传给 _check');
  });

  test('home_page auto-check passes a cacheWriter (background refresh)', () {
    final String src = read('lib/src/pages/implementations/home_page.dart');
    expect(src, contains('cacheWriter: appModel.setUpdateCheckCache,'),
        reason: '启动期后台检查跑完写回缓存');
  });

  test('manual check reads cache optimistically before the network', () {
    final String src = read('lib/src/settings/settings_schema_system.dart');
    expect(src, contains('cachedEntryForChannel('), reason: '手动检查先读缓存');
    expect(src, contains('updateTagIsNewerThanCurrent('),
        reason: '据缓存 tag 判断给「发现新版」/「已是最新」乐观反馈（公开通道感知判定）');
    expect(src, contains('t.update_cached_newer('));
    expect(src, contains('t.update_cached_up_to_date('));
    // 无缓存才退回原「正在检查…」。
    expect(src, contains('t.update_checking_now'));
    expect(src,
        contains('cacheWriter: settingsContext.appModel.setUpdateCheckCache,'));
  });

  test('cache lives in the preferences table (no schema bump)', () {
    final String repo = read('lib/src/models/preferences_repository.dart');
    expect(repo, contains('updateCheckCachePrefKey'));
    expect(repo, contains('UpdateCheckCacheEntry? get updateCheckCache'));
    expect(repo, contains('Future<void> setUpdateCheckCache('));
    // 通过 getPref/setPref（key-value preferences 表），不新建表。
    expect(repo, contains('getPref(updateCheckCachePrefKey'));
    expect(repo, contains('setPref(updateCheckCachePrefKey'));

    final String model = read('lib/src/models/app_model.dart');
    expect(model, contains('UpdateCheckCacheEntry? get updateCheckCache'));
    expect(model, contains('Future<void> setUpdateCheckCache('));
  });
}
