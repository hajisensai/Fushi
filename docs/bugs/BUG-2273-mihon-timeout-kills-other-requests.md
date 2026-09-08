## BUG-2273 · 单个漫画源超时重启共享桥接并中断其它请求
- **报告**：2026-09-08（用户：多个漫画源一起 BRIDGE_IO）
- **真实性**：✅ 真 bug。原 `desktop_mihon_runtime.dart` 的 `_postJson` 对任意 IO/超时调用 `_restart`，杀死所有来源共享的 JVM 并重放请求；一个慢源因此中断其它并发源。
- **[x] ① 根因修复** — `desktop_mihon_runtime.dart:591` 将超时独立上报 `BRIDGE_TIMEOUT`，不终止共享进程、不重放操作。真实子进程死亡仍由保留的进程句柄与 exitCode 生命周期回收。在本修复提交。
- **[x] ② 自动化测试** — `desktop_mihon_runtime_integration_test.dart` 启动真实 JVM，注入单请求超时并同时保留另一未完成请求，验证 PID 不变、慢请求仅一次、另一请求完成、capabilities 仍可用；包含 dispose 后进程消失检查。
- **备注**：该集成测试验证真实桥接生命周期，超时由测试 HTTP 层注入，不等同于用户每个漫画网站的在线端到端验收。
