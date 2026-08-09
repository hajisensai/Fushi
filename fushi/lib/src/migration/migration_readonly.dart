/// 已迁移只读态（改名迁移计划 P1-4）。
///
/// 全部批次导出完成后置位，**每次启动都生效**，直到老版真被卸掉（用户可能在
/// 系统卸载框点「取消」，两版并存是常态而非瞬态）。置位后：
/// - 不自启互联/Yomitan 服务（与 Fushi 端口固定必冲突）；
/// - 不跑自动同步 / 词典自动更新 / 下载入库等后台写手；
/// - PROCESS_TEXT 系统取词入口已注销（`MigrationChannelHandler`）；
/// - 「重新导出」通道保留（Fushi 校验缺批时回头重传）。
const String kMigrationReadonlyPrefKey = 'migration_readonly_v1';
