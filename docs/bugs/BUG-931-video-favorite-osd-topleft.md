## BUG-931 · 视频收藏快捷键唤起进度条+底部提示统一左上角OSD
- **报告**：2026-07-20（用户：）
- **真实性**：✅ 真 bug。根因两处：
  - 进度条：`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:4929` `_toggleFavoriteCurrentCue()` 在收藏前调 `_pokeControlsVisible()`，派发合成 hover 唤醒 media_kit 控制条 → 底栏 seekbar 进度条弹出（碍眼）。
  - 提示位置：视频页收藏/复制/无句可选/资源重链/需重启渲染等提示走全局 `HibikiToast.show(...)`（桌面 `bottom:50` 居中、移动端 `ToastGravity.BOTTOM`），落在屏幕底部；而视频页已有左上角 OSD `_showOsd(...)`（字幕/锁定/画质切换都用它）。两套并存导致部分提示在底部。
- **[x] ① 已修复** — 删收藏路径的 `_pokeControlsVisible()`（仅收藏这一处；seek/重播仍保留 poke）；把视频页 9 处底部 `HibikiToast.show(...)` 全部改走左上角 `_showOsd(...)`（`video_hibiki_page.dart` + `video_hibiki/lookup_favorite.part.dart`）。提交见 PR。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `hibiki/test/pages/video_favorite_osd_guard_test.dart`：断言 `_toggleFavoriteCurrentCue` 体内不再调 `_pokeControlsVisible()`，且 `video_hibiki_page.dart` 与 `video_hibiki/*.part.dart` 全域不再出现 `HibikiToast.show`（视频提示一律走 `_showOsd` 左上角）。
- **备注**：`_showOsd` 是 `_VideoHibikiPageState` 实例方法，part 文件同私有作用域可直接调。不动全局 `HibikiToast`（阅读器/其它页面仍用底部 toast）。
