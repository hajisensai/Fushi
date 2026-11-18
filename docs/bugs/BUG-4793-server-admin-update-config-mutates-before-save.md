## BUG-4793 · 服务端 AdminContext.updateConfig 写盘前就换了内存配置：config.yaml 写失败时内存与文件分家，BUG-4763 的档位回滚也因此不触发
- **报告**：2026-11-17（PR #3643 / BUG-4763 复审：备注里登记的「既有行为」，未单独追踪）
- **真实性**：✅ 真 bug。根因 `packages/fushi_server/lib/src/admin/admin_context.dart:54-59`（修前）先 `_config = next` 和 `serverLanguage = next.language`，再 `await next.save(configFile)`。save 抛出（磁盘满 / 权限）时请求回 500，但 admin 内存配置（GET `/api/admin/srs`、扫描、后续 PUT 的 `copyWith` 基底）已经是新值，config.yaml 还是旧的，重启后又变回旧值。BUG-4763 在 `admin_srs.dart` 依赖「改配置失败 = 没落地」去回滚 RWKV 档位，这条前提因此不成立。
- **[x] ① 已修复** — `admin_context.dart` 的 `updateConfig` 改为先 `save` 再换内存 / 界面语言，最后推给 host；`admin_srs.dart` 带 `rwkvModel` 的 PUT 只在 `!identical(ctx.config, next)`（配置没落地）时把档位写回原值。配置已写盘、只是 `host.applyConfig` 失败时，档位不回滚，免得档位与已落地的配置分家。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/admin_srs_ops_test.dart`「PUT 带 rwkvModel 与别的字段、config.yaml 写不进去：档位文件写回原值，内存配置也不动」：同时改 `rolloverHour`，断言 GET 读回的仍是旧值、档位文件仍是 small。把 `admin_context.dart` 换回修前版本后该用例红（exit=1），修后绿。
- **备注**：admin_api.dart 里另外 3 处 `updateConfig` 调用自动受益，调用方不需要改。
