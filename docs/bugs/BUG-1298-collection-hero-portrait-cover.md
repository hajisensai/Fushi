## BUG-1298 · 合集详情页 hero 用竖版刮削海报时被 BoxFit.cover 裁成中间一条
- **报告**：2026-07-31（用户：截图「刮削封面以后成这样了」，合集 `Tensei Oujo to Tensai Reijou no Mahou Kakumei v2 播放列表`）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart:325`（修复前 `_buildHero` 内无条件 `Image(image: cover, fit: BoxFit.cover)`）

  合集详情页 hero 是宽幅槽：宽 = 整屏，高 = `(screenH * 0.62).clamp(400, 600)`，比例约 **2.7:1**。
  它的图源 `_heroCover` **第一优先**取 `MediaCollections.coverPath`——而刮削正是往这一列写**竖版海报**。
  用户生产库实测：`media_collections.id=69` → `video_covers/collections/69.jpg` = **853×1200（2:3，比例 0.711）**。

  `BoxFit.cover` 把 2:3 海报铺进 2.7:1 槽，缩放因子取 `max(3840/853, 1400/1200) = 4.5`，
  缩放后 3840×5400，垂直裁掉 4000px —— **只剩海报中间 26% 的高度带**，于是画面成了一条糊满
  人脸、头顶被切的横带，正是用户截图所见。

  刮削**前** `cover_path` 为 NULL，`_heroCover` 回落到成员抽帧（16:9≈1.78），cover 只裁掉约 35%，
  看着正常 —— 所以现象精确表现为「刮削封面以后成这样了」，而不是一直就坏。

  更深一层：`media_collections` 只有单一 `cover_path` 列（无 backdrop 列），一个列同时服务
  2:3 网格卡与 2.7:1 hero 两种朝向。朝向矛盾在数据层无处安放，故判定必须落在渲染层。

- **[x] ① 已修复** — 新增 `hibiki/lib/src/media/video/cover_ui/landscape_cover_image.dart`
  （`LandscapeCoverImage`，既有 `PortraitCoverImage` 的镜像：那个管「竖槽装横图」，这个管
  「横槽装竖图」），并在 `_buildHero` 接入：
  - 横图（宽高比 ≥ 1.2，抽帧 16:9）→ 仍 `BoxFit.cover` 铺满，**与修复前逐像素相同**；
  - 竖图（刮削海报 2:3）→ 同图模糊垫底（sigma 28）+ 压暗 + 前景 `BoxFit.contain` 完整显示，
    按 `foregroundAlignment` 靠尾侧（LTR 下 = 右）避让 hero 左下的标题/进度/播放按钮；
  - 首帧解码前尺寸未知 → 按横图渲染（= 修复前行为），`ImageStream` 拿到固有尺寸后再切，不闪换；
  - hero 那两层可读性渐变改为 `overlays` 参数注入组件，由组件排层序：渐变压在模糊垫底**之上**
    （保住文字可读），但压在清晰海报**之下**——否则 hero 底部浓到 `0xE8` 的渐变会把海报下半截
    压成一片黑，等于换个方式毁掉海报。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/collection_hero_cover_orientation_test.dart`（4 例）：
  横图仍 cover 且无模糊垫底 / 竖图（用实测的 853×1200）有模糊垫底且前景 contain / 竖图层序
  （垫底 < 遮罩 < 清晰海报）/ 源码守卫锁 `_buildHero` 调用点不得回退裸 `Image`。

  **变异实测**（防假绿，4 轮全部按预期红/绿）：
  1. 阈值 `1.2 → 0.5`（竖图被误判成横图）→ 竖图 2 例红、横图与源码守卫绿；
  2. `overlays` 与前景 Padding 对调（渐变压到海报上）→ 仅层序 1 例红；
  3. / 4. 调用点换回裸 `Image(image: cover ...)` → 源码守卫红。

  变异期间抓到守卫**自身**的缺陷并已修：原正则 `Image\(\s*image: cover` 会匹配
  `LandscapeCoverImage(` 的尾部（它就以 `Image(` 结尾），当时之所以绿只是因为中间恰好隔了一行
  `key:`；删掉 `key:` 行这一**等价正确写法**会被误判成回归。已收紧为
  `(?<![A-Za-z_])Image\(\s*image: cover`，并实测「删 key 行仍绿 / 裸 Image 仍红」。

- **备注**：本次只做渲染层根因修复，对已刮削的存量数据立即生效、零迁移。
  数据层的彻底解法（`media_collections` 增独立横版 backdrop 列、刮削同时抓 backdrop、hero 优先
  用 backdrop 而海报只喂 2:3 网格卡）需要 schema bump + 刮削源改造，未在本轮范围内；本修复是那条
  路落地后的天然回落路径，不冲突。

  同源但不同槽向的既有条目见 BUG-1299（三处硬编码封面槽绕过 `PortraitCoverImage`）。
