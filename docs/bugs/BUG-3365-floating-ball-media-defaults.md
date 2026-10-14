## BUG-3365 · 漫画等媒体页悬浮球出厂带一长列应用外按钮
- **报告**：2026-10-14（用户：Android 漫画阅读器截图「怎么这么多按钮，默认很多 app 外的按钮怎么在漫画里面显示了」——展开的应用内悬浮球：关闭 + 上一页 / 下一页 / 显示识别范围 / 重新识别本卷 + 查词 / 应用外查词 / 剪贴板查词 / 截屏识字 / 拍照查词 / 反馈，共 11 颗；另指出「上一页」画成 `>`、「下一页」画成 `<`）
- **真实性**：✅ 真 bug，两处：
  1. `fushi/lib/src/floating_ball/floating_ball_config.dart` `FloatingBallScope.defaultButtons` 对**每个**场景都追加全部 `onByDefault` 全局按钮（旧 `onByDefault => this != sync`，与场景无关），漫画 / 视频 / 阅读器这些已有一整排专属按钮的媒体页，出厂又叠上应用外查词 / 剪贴板 / 截屏识字 / 拍照这些与当前媒体无关的入口。用户没在 设置 → 悬浮球 里单独勾过（`floating_ball.buttons.manga` 空串）就走这份出厂值。
  2. `fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_buildMangaFloatingBallScene` 按 `_spreadDirection == 'rtl'` 把上一页 / 下一页图标镜像（物理翻页方向）；悬浮球是竖排「图标 + 文字」，与页面左右无空间对应，结果是「上一页 ›」。
- **[x] ① 已修复** — (1) 出厂全局按钮改按场景定 `FloatingBallGlobalAction.onByDefaultIn(scope)`：`sync` 处处不勾；`system`（应用外球）其余全勾不变；`reader` / `manga` / `video`（`FloatingBallScope.isMediaScene`）只勾 `lookup` 与 `feedback`；`general` 除 `popup_lookup`（应用内另开独立查词窗，与查词重复）外全勾。只改出厂值，用户已保存的勾选不动，目录里这些按钮仍可自己勾回；旧版单份全局勾选 `floating_ball.actions` 的迁移改为全局按钮完全按旧勾选（不再被收窄后的出厂值筛掉）。spec `docs/specs/2026-09-28-floating-ball.md` 同步。(2) 漫画球上一页恒 `chevron_left`、下一页恒 `chevron_right`。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/floating_ball_test.dart`：出厂按钮逐场景断言、「媒体页出厂不带与当前媒体无关的应用外入口」、旧勾选迁移保留剪贴板、「漫画球的上一页 / 下一页图标跟文字走」源码守卫；`fushi/test/floating_ball/app_floating_ball_host_test.dart`「出厂：场景专属按钮排在全局按钮前面」在真实宿主里断言视频场景有反馈、没有应用外查词 / 剪贴板 / 截屏识字 / 拍照。
- **备注**：—
