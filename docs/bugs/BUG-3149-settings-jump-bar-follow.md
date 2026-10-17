## BUG-3149 · 设置页分组跳转条不跟随当前分组横向滚动
- **报告**：2026-10-09（用户：应用内反馈 anuYVUChGs，Android「设置 → 视频」）
- **真实性**：✅ 真 bug。「设置 › 视频」顶部的分组跳转条（HDR / 画面 / 色彩 / 字幕 / 字幕行为与来源 / 音频…）是所有 `SettingsKitScaffold` 设置页共用的 `SettingsSectionJumpBar`（`fushi/lib/src/settings/settings_kit.dart`）。它只是一条横向 `ListView.separated`，当前分组（`activeId`）随正文滚动变化时只重画胶囊颜色，从不滚动跳转条自身——正文滚到「音频」时，高亮的「音频」胶囊停在屏幕右侧外。懒建的 `ListView` 还意味着离屏胶囊连几何都没有，想补滚动也定位不到。
- **[x] ① 已修复** — 跳转条改为有状态组件：分组一次全部建出（`SingleChildScrollView` + `Row`，分组只有寥寥几个），每个胶囊一把 key；`activeId` 变化后在帧末量当前胶囊在跳转条视口里的位置，不完整可见就只滚跳转条自己这一层（两侧各留 24 余量让相邻胶囊露头），不经 `Scrollable.ensureVisible`，不会连带打断外层正文的纵向滚动。所有设置页一起受益。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_section_jump_bar_follow_test.dart`：384 宽下七个分组，`activeId` 切到「音频」后其胶囊完整落在跳转条可见区，切回「HDR」同样；已在可见区的胶囊切换时跳转条不动。
- **备注**：截图里跳转条还压在内容卡片上，那是 M3E 叠放页头的既有设计（正文从页头下滚过，靠顶部渐隐保证可读），本次未改。
