## BUG-3056 · FushiSpring 弹簧落定不吸附终值：浮动工具条停在离目标约 1e-3 处（亚像素偏移）
- **报告**：2026-10-06（PR #1984 CI：`fushi_floating_chrome_test` 两条红，落定后偏差 -0.0008 / +0.00095 px）
- **真实性**：✅ 真 bug。`FushiSpring.animateTo`（`fushi/lib/src/utils/components/glass/fushi_expressive.dart`）构造 `SpringSimulation` 时没开 `snapToEnd`：模拟按默认容差（1e-3）判结束，控制器停在离目标千分之一处。`FushiFloatingChromeOverlay` 用未截断的弹簧值做位移，收起后底边仍探进叠放区、展开后不贴顶，工具条永久带亚像素平移（文字被重采样发虚）。motion token 层的 `FushiSpringSpec.simulation` 早已 `snapToEnd: true`，这里是漏网。
- **[x] ① 已修复** — `SpringSimulation(..., snapToEnd: true)`（`fushi_expressive.dart:135`）。影响面：全部 `FushiSpring` 使用点（约 38 处）落定值精确等于目标，过程轨迹不变。提交 `f02f8bc2333`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_test.dart`「焦点走进收起的工具区时立刻弹回」「叠放工具区…」两条钉精确落点。
- **备注**：配套测试修正（交互后先泵一帧再推进弹簧）见 `3e2fb891113`。
