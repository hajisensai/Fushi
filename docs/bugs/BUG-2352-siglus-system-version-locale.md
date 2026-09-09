## BUG-2352 · Siglus旧版读取系统版本资源时日语转区仍被判定失败
- **报告**：2026-09-08（原始 Rewrite 转区启动验证）
- **真实性**：✅ 真 bug。原版游戏读取系统 kernel32.dll 的版本 Translation，并要求日语 LANGID 0411。CP932/LCID/UI 语言转区仍返回系统资源 0804；原路径停在该检查。上游存在未注册的旧资源改写函数，但其固定 TLS 缓冲与资源长度契约不安全，未启用。
- **[x] ① 根因修复并完成本地回测** — third_party/locale_emulator/version_query_hooks.inc 在 VERSION 公有 API 成功后处理调用者拥有的缓冲；parser 验证完整资源及对应字符串表后原子修改语言。审查补齐手工映射/正常加载生命周期和失败清理。最终候选已重建，自有探针及原始 Rewrite 启动链均通过；正式随包运行库未更新。
- **[x] ② 已加自动化测试** — locale_emulator_version_resource_test.cpp 的 13 组覆盖有界解析、字符串表一致性和真实 Windows API；locale_emulator_version_hooks_test.cpp 的 15 组直接编译生产集成代码，覆盖部分安装/恢复失败、trampoline 保留、API 失败不写缓冲及映射所有权。Windows x86/x64 Release 均通过。
- **备注**：最终候选 `8DF7A41BE6AE8C6920CB06C05C60DAEFDA9D330A0212A1CC036DE9B877CA9079`，自有探针 26152 返回 0411/04b0 并正常退出；2026-09-08 原始 Rewrite 71692 → 64428 → 46800 进入正文。构建使用正式 v140 19.00.24247.2 与 LLVM 22.1.6，并通过生产 PE 契约校验。只证明本地兼容边界，不升级引擎支持或分发状态。
