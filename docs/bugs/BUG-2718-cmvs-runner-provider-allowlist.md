## BUG-2718 · CMVS 精确布局的查词命中被 runner 白名单丢弃
- **报告**：2026-09-27（P1 路线图推进时代码审查发现，未经用户报告）
- **真实性**：✅ 真 bug（代码路径确认，未真机复现——本机无 CMVS 样本）。查词 provider 的生产 (kind, id) 白名单在三个构建单元各抄一份：native `native/galgame_hook/hook/geometry_provider_registry.h:83`（含 `{EngineExactLayout, Cmvs=16}`）、Dart `fushi/lib/src/platform/gal_hook_text_overlay_channel.dart:69`（含 16），但 runner 的 `fushi/windows/runner/lookup_hit_validation.h:91` `IsProductionProviderPair` 与 `attached_text_surface_window.cpp` `NativeProviderPreferred` 两处都只到 15。`voice_hook_reader.cpp` `PollLookupHit` 校验不过即丢弃，CMVS 的 Shift 查词 hit 永远到不了 Dart，且 runner 不把 CMVS 视为原生 provider、仍走 attached 覆盖层。三边都不报错。
- **[x] ① 已修复** — runner 白名单补 16；`NativeProviderPreferred` 改为直接复用 `IsProductionProviderPair`，删掉第二份手抄表与随之无用的三个 kind 常量。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_lookup_provider_allowlist_parity_test.dart`：解析 native 注册表（常量值取自 `voice_hook_ipc.h`）、runner switch 与 Dart 谓词，要求三者逐对相等（attached_calibrated 仅 native）；并禁止 `NativeProviderPreferred` 再手抄 id。runner C++ 单测 `lookup_hit_validation_test.cpp` 补 (2,16)/(2,17) 断言。
- **备注**：CMVS 真机 E2E 仍未跑（样本缺失），支持状态不因本修复升级。
