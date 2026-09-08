/// 引擎读写偏好的窄接口。
///
/// app 的 `PreferencesRepository`（2900 行、依赖 material）只有 `getPref` /
/// `setPref` 两个方法被引擎用到（刮削配置、追番令牌与同步游标）。让它
/// `implements PrefStore`，引擎只认这个接口；无头服务端用自己的 `preferences`
/// 表实现。
///
/// 两个签名刻意与 `PreferencesRepository` 逐字一致，`implements` 零适配。
library;

abstract interface class PrefStore {
  dynamic getPref(String key, {dynamic defaultValue});

  Future<void> setPref(String key, dynamic value);
}
