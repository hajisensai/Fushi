## BUG-2223 · 热力图档位按窗口最大值线性分级，单日爆量后其余全落最浅档
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/stat_contribution_heatmap.dart:138-166`：档位按占当前可见窗口 `maxValue` 的**比例**线性四档。某天百万字（导入 / 长途阅读）会让其余所有活跃日全落最浅档，整张图只剩一个深格；翻页时同一天的颜色随窗口最大值变。
- **[x] ① 已修复** — 对齐 Hoshi Android 的分位数着色：新增纯函数 `statHeatmapRankLevel(value, sortedActive)`，档位按窗口内活跃日数值的**秩**分 1..4（`⌈r/n × levels⌉`，整数运算），零值仍最浅档；`buildStatHeatmap` 改用它。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/stat_contribution_heatmap_test.dart`（单日爆量不再把其余压成最浅档、均匀分布各档人数接近、同值同档、零值 0 档、单活跃日 4 档）。
- **备注**：
