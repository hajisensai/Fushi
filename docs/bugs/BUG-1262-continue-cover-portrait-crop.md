## BUG-1262 · 竖版海报封面在继续/继续观看/合集详情被裁切或留灰带
- **报告**：2026-07-31（用户：截图报「如果是海报，在继续里面和继续观看里面渲染有问题」）
- **真实性**：✅ 真 bug。刮削（Bangumi/TMDB）会把竖版 2:3 海报写进 `video_books.cover_path`（与抽帧封面同路径同列，无横竖标记），但三处消费端都是硬编码横版槽 + 固定 fit，全部绕过了视频库主网格已在用的自适应组件 `PortraitCoverImage`：
  - 首页「继续」卡：视频条目走 234×132 的 16:9 槽 + `BoxFit.cover`（`hibiki/lib/src/pages/implementations/home_dashboard_page.dart:1290`，`_videoCover`），竖版海报上下被裁掉约 62% 只剩中间一条；
  - 视频首页「继续观看」hero：148×84 硬槽 + `BoxFit.contain`（`hibiki/lib/src/pages/implementations/home_video_page.dart:2250`），竖版海报两侧各露约 50px surfaceContainer 灰带；
  - 合集详情单集缩略图：96×54 硬槽 + `BoxFit.cover`（`hibiki/lib/src/pages/implementations/media_collection_detail_page.dart:228`，`_episodeThumb`），同样裁成中间一条。
- **[x] ① 已修复** — 根因修复：`PortraitCoverImage` 推广为槽向自适应（新增 `landscapeSlot`，横槽内竖图改模糊垫底 + contain）；「继续」卡消灭视频专属宽度特例，三类条目统一 94×132 竖版槽走 `PortraitCoverImage`；「继续观看」hero 换 80×120 竖版槽走既有 `poster: true` 路径；合集详情缩略图保留 96×54 槽但改 `landscapeSlot: true` 自适应。提交：见本分支。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/portrait_cover_image_test.dart`（组件四象限行为：竖槽竖图铺满/竖槽横图垫底/横槽横图铺满/横槽竖图垫底）+ `hibiki/test/pages/continue_cover_portrait_guard_test.dart`（源码扫描守卫：三处消费端必须走 PortraitCoverImage、禁止回退硬编码 fit）。
- **备注**：封面数据模型无横竖/来源标记（`cover_meta.json` 仅刮削侧防覆盖用），故修复统一走运行时解码宽高比判定（`ImageStream` 零额外解码），与主网格同源。
