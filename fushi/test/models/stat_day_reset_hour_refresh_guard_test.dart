import 'dart:io';

import 'package:test/test.dart';

/// BUG-5073：统计日界（`stats_day_reset_hour`）随 Profile 走，`FushiDatabase.statDayResetHour`
/// 是它的进程级镜像。切 Profile / 别的进程改过偏好都走 `AppModel.refreshPrefCache`
/// 整体重载偏好缓存；那里不重新镜像，新 Profile 就一直按旧日界切「今天」直到重启。
///
/// `refreshPrefCache` 会碰媒体源 / 主题 / Anki 后端等没初始化的子系统，宿主单测驱动
/// 不了（`app_model_pref_refresh_gating_test` 也是整段覆写掉），所以用源码扫描钉死：
/// 它的方法体里必须调 `_applyStatDayResetHour()`，且在 `refreshFromDb()` 之后。
void main() {
  test('refreshPrefCache 重载偏好后重新镜像统计日界', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int start = src.indexOf('Future<void> refreshPrefCache() async {');
    expect(start, isNonNegative, reason: '找不到 refreshPrefCache');
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    final int reload = body.indexOf('await prefsRepo.refreshFromDb();');
    expect(reload, isNonNegative, reason: 'refreshPrefCache 不再重载偏好，守卫需要跟着改');
    final int apply = body.indexOf('_applyStatDayResetHour();');
    expect(
      apply,
      greaterThan(reload),
      reason:
          '切 Profile 后偏好已换成新 Profile 的值，必须在 refreshFromDb 之后重新镜像进 '
          'FushiDatabase.statDayResetHour（BUG-5073）',
    );
  });
}
