## BUG-3014 · 隔离集成测试启动仍可能迁移用户真实支持目录
- **报告**：2026-10-06，BUG-3008 Windows 专项启动前的隔离边界审查（HBK-AUDIT-061）。
- **真实性**：✅ 真 bug（真实启动路径与插件代码确认；未对用户目录执行迁移）。修前 `fushi/integration_test/support/test_app_launcher.dart:18` 和 `fushi/lib/main.dart:245` 都无条件调用 `migrateLegacySupportDir`，旧入口直接调用 `getApplicationSupportDirectory`，未检查 `FUSHI_TEST_ROOT`。Windows `path_provider_windows 2.3.0` 使用 `SHGetKnownFolderPath(RoamingAppData)`，不靠测试 runner 重定向的 `APPDATA`，且解析过程本身可创建目录。随后旧入口会移动真实 Hibiki 根，或清除真实 staging；即使 Fushi 根已存在也不能保证无写入。已有 SharedPreferences 隔离不能保护这个独立入口。
- **[x] ① 根因修复**（`80feb302326`）— 在 `fushi/lib/src/storage/legacy_support_dir_migration.dart:47` 复用测试根解析并提前返回 `notApplicable`，必须发生在平台目录解析之前；同一入口覆盖 main 与集成 launcher。未设置测试根时保留正常迁移。测试注入参数默认仍调用真实目录解析，无新增依赖。
- **[x] ② 增加自动化测试**（Windows 本机 4/4 通过；两条隔离门用例与平台无关，Linux CI 同样执行，只有两条「照常迁移」依赖 Windows 目录布局）— `fushi/test/storage/legacy_support_dir_test_isolation_test.dart`：环境变量与 dart-define 各验证 resolver 零调用、旧根/当前根/staging 保持原样；空串与空格各验证正常搬迁。所有文件仅在测试自己创建的临时根内。集中批另外覆盖现有迁移、桌面身份与 SharedPreferences 隔离回归。
- **备注**：保护验证通过前不启动真实 Windows 专项。尚无用户真实数据受影响的证据，不把代码路径风险描述为已发生损失；本项不代表所有原生插件目录都已完成隔离审计。
