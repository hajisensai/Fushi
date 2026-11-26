## BUG-5538 · curator-ai-blocked-no-auto-recovery
- **报告**：2026-11-27（合并 PR #4516 时审查发现）
- **真实性**：✅ 真问题（待拍板的行为设计，未修）。BUG-5531 之后，自动路径碰到额度用尽 / 鉴权被拒就把 `LibraryCurateState.aiBlocked` 持久化（`packages/fushi_engine/lib/media/library_curate/library_curator.dart` `_runLocked` 收尾），之后自动路径整趟不发 AI。解除只有两条路：手动跑一趟，或关掉再打开「AI 库管家自动整理」开关（`fushi/lib/src/settings/settings_schema_ai.dart` 该开关的 onChanged）。用户充值或换 key 之后，自动路径一直只跑规则，界面上没有任何提示：`_showCurateResult` 只在手动跑时弹，设置页和待确认页都不显示停用状态。对照：AI 助手复查的熔断在换了提供商后会自动恢复（`fushi/lib/src/media/library_curate/library_agent_review.dart:176`）。
- **[ ] ① 未修复** — 建议：把指派的提供商身份（providerKey）一起记进 `aiBlocked`（或并进库变化戳），换了提供商就自动解除；设置项副标题显示「AI 已因 xxx 停用」，并给一个恢复入口。会改用户可见行为，先交用户拍板。
- **[ ] ② 未加自动化测试** —
- **备注**：同一次审查还发现，每趟有改动的自动跑之后会多空转一趟：存的是开跑前的戳，这一趟自己建的合集、刮到的作品会改变戳。不能简单改成存收尾时的戳，那样会把开跑期间用户新入库的变化一起吞掉。正确做法是区分「本趟自己的写入」和「外部写入」，等本条拍板时一并设计。
