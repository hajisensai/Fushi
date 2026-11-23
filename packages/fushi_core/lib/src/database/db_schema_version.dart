/// 本构建的用户库 schema 版本（`FushiDatabase.schemaVersion` 的唯一来源）。
///
/// 升级迁移时只改这里。它还有两个读者：
/// - CI `tool/publish_update_manifest.sh` 按正则 `kFushiDbSchemaVersion = <N>;` 抠出这个数，
///   写进更新清单每个 asset 的 `dbSchemaVersion`（改写法要同步那条正则与守卫测试）；
/// - 应用内更新器拿它和远端 asset 的 `dbSchemaVersion` 比：远端更低 = 装上就会因
///   「数据库比程序新」拒绝打开用户库，一律不推（见 `selectUpdateReleaseForCurrentPlatform`）。
const int kFushiDbSchemaVersion = 174;
