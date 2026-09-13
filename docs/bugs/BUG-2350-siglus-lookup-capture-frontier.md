## BUG-2350 · Siglus同句重绘前沿未消费时永久丢弃已入队查词点击
- **报告**：2026-09-07，SPRB 原版 PID 30476 查词点击已入队且被消费，但未发布命中。
- **真实性**：✅ 真 bug。原 `siglus_lookup.inc::ProcessSiglusLookupTick` 先确认消费点击，再由 `IsSiglusLookupPayloadCurrent` 拒绝尚未消费的新 glyph；渲染线程在两步之间提交同句重绘即可永久丢失一次物理点击。生产 worker 路径回归测试复现该交错。
- **[x] ① 根因修复** — `native/galgame_hook/hook/adapters/siglus_lookup_worker.inc` 区分终止拒绝、等待捕获与发布成功。四槽 FIFO 内保留等待事件，仅在捕获消费前沿推进后重新验证；文本事件、布局 epoch、窗口或坐标变化立即终止。glyph 环覆盖使旧 epoch 失效。会话重置清除待提交事件。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/siglus_lookup_worker_test.cpp` 直接包含生产 worker；15 个场景覆盖两次发布检查之间的重绘、等待无进展、持续完整重绘、部分重绘、同字新事件、窗口/前台/会话变化、环覆盖及 registry 拒绝。x86/x64 优化编译执行；完整分发构建及原路径回归由集成工作区继续验证。
- **限制**：不会在 glyph 前沿未消费时放宽发布条件；生产者持续领先时仍需等待。没有重试次数、延时或文本字符串回退。当前记录证明生产路径回归，尚不等于新版 DLL 的游戏运行验收。
