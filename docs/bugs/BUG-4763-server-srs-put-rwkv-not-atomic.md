## BUG-4763 · 服务端 admin PUT 同时改 RWKV 档位与别的复习配置时不原子：档位文件写不进去时报 500，但其它字段已经生效
- **报告**：2026-11-17（用户：PR #3561 合入后的遗留审查项「PUT 同时给 rwkvModel 与其它字段时，先写 config.yaml 再写 model_size，不是原子操作」）
- **真实性**：✅ 真 bug（修前新增用例稳定红：期望 500 且 `rolloverHour` 不变，实际 `rolloverHour` 已改、config.yaml 已写）。根因：
  - `packages/fushi_server/lib/src/admin/admin_srs.dart:320`（修前行号）先 `await ctx.updateConfig(next)`（写 config.yaml + `host.applyConfig`，`admin_context.dart:54-60`），`:322` 才 `srs!.setRwkvModelSize(rwkvSize)` 写 `<support>/srs_rwkv/model_size`（`server_srs.dart:401-404`）。后者因磁盘满 / 权限失败时整次回 500，但 `rolloverHour` / profiles / ankiConnect 等字段已经写盘生效；管理员以为整次失败，实际配置变了一半。
- **[x] ① 已修复** — 档位文件改成最先写：`admin_srs.dart:328` 先 `ServerSrs.writeRwkvModelSize`（`server_srs.dart` 新增，只写文件不对齐），写不进去直接 500、config.yaml 与内存配置不动；`:330` 再 `ctx.updateConfig(next)`，失败时把档位文件写回原值再抛；最后 `running.applyConfig()` 让在用的 RWKV 服务按文件换档。不带 `rwkvModel` 的 PUT 路径不变。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/admin_srs_ops_test.dart`「PUT 同时给 rwkvModel 与别的字段、档位文件写不进去：整次 500，config.yaml 与内存配置都不动」（用目录占住 `model_size.tmp` 让写入失败；对修前 `admin_srs.dart` 跑红，修后绿）与「PUT 带 rwkvModel、改配置失败：档位文件写回原值」（用目录占住 config.yaml）。
- **备注**：`AdminContext.updateConfig` 本身在 `save` 前就换了内存配置（save 失败时内存与文件不一致），属既有行为、不在本条范围。
