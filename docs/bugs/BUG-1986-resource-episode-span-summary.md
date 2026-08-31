## BUG-1986 · 资源版本卡把非连续集号显示成连续范围
- **报告**：2026-08-31（用户：资源版本卡显示“共 5 集（EP1–EP17）”）
- **真实性**：✅ 真 bug — `fushi/lib/src/pages/implementations/video_resource_version_group_list.dart:68-82` 的 `_metaLine` 用集号集合的最小值和最大值拼区间；即使真实集合只有 5 个离散集号，也会显示成覆盖 17 集的连续范围，数量与范围自相矛盾。
- **[x] ① 已修复** — 新增 `formatVideoResourceEpisodeSpans`，排序去重后的真实集号按连续段压缩；例如 `{1,2,4,16,17}` 显示为 `EP1–EP2, EP4, EP16–EP17`，只有集合本身连续时才显示单一区间（本分支提交）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_resource_version_group_list_test.dart` 覆盖离散段、单集、连续集，并通过 widget 断言版本卡显示真实段且不再出现 `(EP1–EP17)`。
- **备注**：版本卡纯函数与 widget 定向测试通过；Windows 真 app 原始搜索路径待复测。
