## BUG-2235 · Siglus OVK 导出失败仍报告已捕获
- **报告**：2026-09-07（用户要求 Siglus 音频也达到引擎级适配，审计发现）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/siglus_adapter.inc:392` 忽略 `WriteVoiceOggAt` 返回值，在归档 entry 读取与 Ogg 结构校验成功后无条件发布 Dumped/Captured；`hook/dll_main.cpp:244` 的真实 writer 会因建目录、创建、写入或关闭失败返回 false。源 entry 有效不等于目标文件落盘成功。
- **[x] ① 根因修复** — 本文件同提交将两项 capture 标志放到 writer 成功分支，失败仍走原有内存和句柄释放，不重试、不吞写入失败、不清除其他已成功事件的粘滞状态。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py::test_siglus_ovk_capture_requires_successful_export` 检查生产 worker 的成功分支拥有唯一的两项标志发布，且成功/失败共同清理仍在分支外。针对性结果记入本轮审查报告；此守卫不是磁盘故障真机注入测试。
- **备注**：当前 LUNARiA 原路径会话确有九个原 entry 与导出 Ogg 的完整哈希相等；没有在用户磁盘上制造写失败。诊断修正不证明角色归属、稳定正文事件配对、或制卡 E2E；这些仍须独立验收。
