## BUG-3417 · 推荐包重新导出抬高schema导致旧版强制更新
- **报告**：2026-10-16（用户：推荐包导入提示需要更新应用，schema 117）
- **真实性**：✅ 真 bug。`fushi/tool/pack/export_recommended_pack.dart` 直接用当前 `FushiDatabase` 导出，将原推荐包实际 schema 86 升为 117；`fushi/lib/src/sync/backup_service.dart:1557` 将该版本写入清单，`fushi/lib/src/sync/sync_settings_schema/backup.part.dart:1044` 因高于旧客户端支持版本而拒绝导入。此外新词典原生磁盘格式为 v2，旧包原有词典全为 v1，仅修改清单版本不能解决兼容问题。
- **[x] ① 已修复** — 增加 `extend_recommended_pack.py`，从已发布基线的真实数据库结构增补对应词典记录和资源；只读新元数据所需旧列，不迁移数据库、不改小 user_version。公开分发副本继续精确白名单净化与 VACUUM；原导出入口强制要求兼容基线并拒绝静默提高 schema。新词典通过真实旧版 DLL 重新导入为 v1，原始 ZIP 不变。提交见本文件所属提交。
- **[x] ② 已加自动化测试** — `fushi/tool/pack/test_extend_recommended_pack.py` 21 个测试验证真实旧 schema 和 sqlite_master 不变、117 源不混入新表/字段、旧词典与音频资源保留、隐私清理及触发器回写阻断、同名资源替换、非法输入和失败无半包；实际 21/21 通过，无跳过。另执行真实导出入口，确认 schema 117 对 86 基线在生成产物前被拒绝。
- **旧版验收**：正式版 `v2.9.1`（`689f44456c`，schema 116）的真实 `validateBackup`、合并恢复、覆盖恢复均通过；实际运行 1 个测试，退出码 0。两条路径各有 27 本词典、197 个资源文件，逐文件 CRC 和新词典 SHA256 与最终 ZIP 一致，实际 schema 86→116 迁移成功。恢复后的目录再经旧 DLL 查询「完全」「100パーセント」，完整结果及释义哈希一致。属于旧版真实组件/原生引擎验收，未点击发布版 UI；音频未在该测试复制，但其文件与旧推荐包大小/CRC、音频注册项已分别逐字节核对。
- **备注**：产物、旧 DLL 来源及哈希、日志和验收脚本保存在 `D:/辞典/pack-2026-10-16-r1/`，发布到独立 `hajisensai/fushi-pack` 的 `pack-2026-10-16-r1`；不得将只改版本号或只测当前开发版当作兼容验证。
