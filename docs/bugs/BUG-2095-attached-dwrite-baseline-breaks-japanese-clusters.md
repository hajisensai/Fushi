## BUG-2095 · attached 子面 DirectWrite 基线硬编码 0.8em，日文正文必然上溢版面框，字形簇永远建不出来
- **报告**：2026-09-03（BUG-2094 把活锁解开后，attached 前进到「有认领、有正文、就是建不出簇」，继续逐点收敛得出）
- **真实性**：✅ 真 bug，真机上一改即通：修前 `fallback/overhang_outside_body_rect`，修后当场 `activeAttached`。
- **定位过程**：`RebuildClusters()` 有 **20 个失败点，全部是裸 `return false`**，对外只发一条笼统的 `noGlyphClusters`——真机上等于「二十选一」。本轮先逐点补上原因（纯量具），真机立刻读出 `overhang_outside_body_rect`；在此之前我按「大概是版面太窄」猜过两轮宽高，全部是盲改。
- **根因**：`fushi/windows/runner/attached_text_surface_window.cpp` 的
  `format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, line_spacing, font_size * 0.8f)`
  ——第三个参数是「行顶到基线」的距离，硬编码成 `0.8 × font_size`。那是拉丁字体的经验值；日文字体（Yu Gothic 等）的 ascent 普遍在 **0.88 em** 上下，于是**第一行的墨迹必然伸到版面框上方约 0.08 em**，紧接着的
  ```cpp
  if (FAILED(GetOverhangMetrics(&overhang)) || overhang.top > kLayoutEpsilon || ...) return false;
  ```
  恒判 `overhang.top > 0` 而整轮建簇失败。**attached 通路对日文正文因此永远建不出一个字形簇**，与校准的矩形宽高、字号、行距全都无关——换句话说这条兜底通路在日文上从来没真正跑通过，只是以前没人把失败原因读出来。
- **[x] ① 已修复** — 不去猜一个新常数，而是**量出来**：先用一次性版面（同字体、同字号、同行距）读 `GetOverhangMetrics`，把测到的 `overhang.top` 加回基线，再建正式版面。
  - 本来就不上溢的字体量到 0，基线一字不变 —— 存量校准的垂直位置不受影响。
  - 上溢的字体正好抵消，`overhang.top` 归零，既有的严格 overhang 校验**一条都没有放宽**。
- **[x] ② 同轮补齐的量具（是本条能被定位的唯一原因）** — `RebuildClusters()` 20 个失败点逐点报因：`empty_text_or_no_surface_rect` / `dwrite_factory_failed` / `calibration_rect_invalid` / `layout_bounds_too_small` / `create_text_format_failed` / `create_text_layout_failed` / `metrics_overflow_body_rect` / `overhang_outside_body_rect` / `line_metrics_unavailable` / `line_metrics_read_failed` / `line_trimmed` / `line_units_or_height_mismatch` / `cluster_metrics_unavailable` / `cluster_count_zero` / `cluster_metrics_read_failed` / `cluster_range_out_of_text` / `hit_test_range_empty` / `hit_test_range_failed` / `cluster_box_outside_surface` / `text_position_mismatch` / `clusters_empty`；`SetState` 带出具体 token。另外 `layout_dirty_` 为假那一轮本来会用泛化的 `clusters_empty_after_build` **覆盖掉上一轮的真因**，改成保留 `last_cluster_failure_`。
- **真机证据**（WoH v1.0，client 1874×1049）：
  ```
  修前：attached=fallback/overhang_outside_body_rect
  修后：attached=activeAttached/null   → 点字弹出查词卡、剧情不推进（同一轮实测）
  ```
- **[ ] ③ 待补自动化测试** — 计划在 `fushi/windows/runner` 的可测层加一条纯函数守卫：给定字体 ascent > 0.8em 时，基线必须 ≥ ascent（即 `overhang.top ≤ 0`）。当前该逻辑与 DirectWrite 实例耦合，抽出前先记在此。
- **关联**：[[BUG-2094]]（先解开活锁才走到这一步）、[[BUG-2092]]（同一条「状态不带原因就无法定位」的纪律，这次发生在 native 侧）、[[BUG-2096]]（本条修好后暴露的下一道边界）。
