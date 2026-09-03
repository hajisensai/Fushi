## BUG-1717 · 漫画缺少默认 keiyoushi 扩展仓库（核查：develop 已内置）
- **报告**：2026-08-18（用户：漫画没有默认的 keiyoushi 扩展仓库）
- **真实性**：❌ 现 develop 未复现（用户所用发布版本较旧）。
  `fushi/lib/src/media/manga/mihon/mihon_manager.dart:18`
  `kMihonDefaultStoreIndexUrl = 'https://github.com/keiyoushi/extensions/raw/repo/index.pb'`，
  `_seedDefaultStore`（同文件 :129）在启动初始化时自动装配，且：
  - 只种一次（`mihon_default_store_seeded` 偏好置位后不再回填，用户删掉不会复活）；
  - 已有同地址仓库时去重跳过，存量配置不被覆盖；
  - 首启断网不置位、下次启动重试；
  - 单测走 `seedDefaultStore` 显式开关，只有真实 app 启动（`AppModel.mihonManager`）传 true。
  落地于 develop `fbdd0b4cdd`（2026-08-02），测试
  `fushi/test/media/manga/mihon_default_store_seed_test.dart` 四条用例全覆盖。
  偏好键经命名常量 `kMihonDefaultStoreSeededPref` 引用，按
  `preference_keys_guard_test` 的纪律「经命名常量引用的键不在扫描面内」无需登记。
- **备注**：无需改动；用户升级到含 `fbdd0b4cdd` 的版本后首次启动即自动获得 keiyoushi
  仓库。
