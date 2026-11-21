## BUG-4961 · 常驻装饰动画按屏幕刷新率逐帧重画：吉祥物光晕 / 主页背景开着时 4K 144 Hz 整窗持续合成，GPU 占用高
- **报告**：2026-11-16（所有者本机，与 BUG-4893 同一份报告：「……而且 gpu 占的很高」）；拍板台 pr3569 第 2 项（2026-11-17 所有者：「想想办法优化，能不降低效果最好」）
- **真实性**：✅ 真问题。BUG-4893 取证时光晕开着、主窗口按 144 Hz 持续出帧，会话标记每 30 s 约 4300 帧、要帧方全是 `_MascotGlowState._syncBreath`；60 px 的呼吸带着整个 4K 主窗口每帧重新合成，raster 线程约 47%、GPU 3D 约 20%。
  - 根因：`fushi/lib/src/utils/scheduling/ambient_ticker.dart` 的 `_AmbientTicker` 与普通 `Ticker` 一样，每帧 tick 完立刻续排下一帧（`Ticker._tick → scheduleTick(rescheduling: true)`），常驻装饰动画于是跟着屏幕刷新率逐帧要帧。Impeller 没有 raster cache、Windows 也没有局部重绘，每一帧都是整窗合成。可这些动画慢到几十秒一个来回（背景漂移单程 40 s、自转 120 s 一圈，光晕呼吸单程 1.4～2.8 s），144 Hz 采样与 30 Hz 采样肉眼看不出区别。主页背景（`page_backdrop_layer.dart`，BUG-4387 备注里的「每帧成本」）是同一个根因。
- **[x] ① 已修复** — `_AmbientTicker` 覆写 `scheduleTick` / `unscheduleTick` / `scheduled`：启动与取消静音照旧立刻排帧（动画即时起步）；每帧 tick 完的续排先等 `FushiMotion.ambientFrameInterval`（25 ms，加上等 vsync 实际约 30 fps）再要帧，等待期间不挂帧回调、不要帧，窗口没别的变化时引擎不出帧。动画值仍由 `AnimationController` 按真实经过时间算，只是采样变稀，呼吸与漂移的幅度、节奏、曲线都不变；静音 / 停止 / 释放时节流定时器一并取消。`AmbientTickers.scheduledFrameCallbackCount` 只数真挂着的帧回调（`super.scheduled`），节流等待不被当成「忙」扣掉。光晕与主页背景都走 `AmbientTickerProviderStateMixin`，一处改动两者同时生效；144 Hz 屏上常驻装饰动画的出帧数约降到原来的 1/4～1/5。
- **[x] ② 已加自动化测试** — `fushi/test/utils/scheduling/ambient_ticker_test.dart`（1 ms 一步 pump 1 s，要帧次数 ≤ 1000/25+2 且仍在走；节流不改动画值，按真实时间推进；节流等待中静音不再要帧、取消静音立刻排帧；页面背景层只数真帧回调）、`fushi/test/utils/components/mascot_glow_test.dart`（光晕开着 1 s 内要帧次数同上限）。
- **备注**：
  - 未在 4K 144 Hz 真机上复测 GPU 占用（无对应设备会话）；出帧数下降由 widget 测试按要帧次数证明，raster / GPU 占用按出帧数等比例估算。
  - 选 25 ms 的依据：光晕忙碌档每 33 ms 透明度变化最多约 0.019（≈5/255，落在一圈模糊光晕上），空闲档 ≈2/255；背景漂移 4K 下峰值约 3 px/s，每步 0.1 px。
