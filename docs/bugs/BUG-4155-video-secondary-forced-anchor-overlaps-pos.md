## BUG-4155 · 副字幕被强制置顶后与同轨顶部定位字幕叠字、控制条显隐时一个动一个不动
- **报告**：2026-11-05（用户：BanG Dream! S2E13 主字幕 = AI 生成 `.ja.ass`、副字幕 = 内嵌英文字幕组轨；顶部英文译文压在左上角罗马音上，控制条一出现英文行单独下移、罗马音不动）
- **真实性**：✅ 真 bug。英文轨的译文行是 `Afterglow` 样式（`\an3` 右下），`resolveLayerForcedAnchor`（`fushi/lib/src/media/video/video_subtitle_style.dart` 的「副字幕对侧置顶」）把它强制拽到顶部居中；同一轨的罗马音是 `\pos(30,10)` 定位行，`_absolutePositioned`（`fushi/lib/src/media/video/video_subtitle_overlay.dart`）照作者位摆放、不参与避让。两组各自定位、互不知道对方 → 叠字。控制条可见时只有锚点组吃 `controlsTopReserve`（`_paddingFor` 顶部分支），于是英文下移、罗马音不动。强制锚定是 Fushi 自己加的排版（libass 里副字幕不存在），却没为挪动后的位置负责。
- **[x] ① 已修复** — 主 / 副两层的位置组摊平进同一个碰撞布局容器 `_CueCollisionStack`：定位盒（`\pos` / `\move` / 帧锚 `\clip`）与主字幕锚点组位置不变（libass 同构），副字幕锚点组摆放后按 `resolveCueYieldOffset` 整组让开它们（顶锚往下、底锚往上，最多让到画面中线；同一批 cue 在屏期间让位线只进不退，障碍物先走字幕不弹回；控制条避让与让位线取下限不叠加）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_secondary_collision_test.dart`：纯函数七例 + overlay 真布局三例（英文副字幕让到罗马音下方、控制条显隐不再单独移动、主字幕不让位）。
- **备注**：未在真机上复测原始失败路径（本轮只有单测 + widget 布局证据）。日语生成字幕缺少的歌词动效（逐字卡拉 OK）另开任务：逐字时间算法在上游 `fushi-subtitles` 的 `_charTimes` / `_alignToStream`，需上游公开后升钉版。
