## BUG-3784 · profile-default-ensure-race
- **报告**：2026-10-26（AI 助手操作目录描述子代理写 Profile 撤销测试时在新建 ProviderContainer 上复现）
- **真实性**：✅ 真 bug。`fushi/lib/src/profile/profile_repository.dart` 的 `ensureDefaultProfile` 是「先查表、空就建 Default」；`ProfileViewModel` 首次被读时异步 `_load()`，控制通道 `_profileViewModel`（`fushi/lib/src/ops/ctl_settings_routes.dart`）紧接着又 `reload()`，两路同时看见空表、都去建，第二路撞 `profiles.name` 唯一约束。冷启动后立刻发 CLI / AI 的 Profile 请求即可触发。仓储有多个实例共用一个库，实例级锁不够。
- **[x] ① 已修复** — `ensureDefaultProfile` 按库对象（`Expando`）合并在途调用，跑完即清，不缓存结果。顺带修同一处发现的 `_copyProfile`：找不到新建的 Profile 时 `orElse: () => source` 把源 Profile 当复制结果返回（撤销会删掉源），改为报 409。另：`PUT /api/admin/ai/providers/:id` 的 name / model 认显式空串（原先 `optString` 把空串当没给，原本为空的字段写不回空）。
- **[x] ② 已加自动化测试** — `fushi/test/profile/profile_repository_test.dart`「两个仓储实例并发 ensureDefaultProfile…」；provider 清空见 `fushi/test/ops/op_undo_data_settings_test.dart`「原值为空的字段…」。
- **备注**：
