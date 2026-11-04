## BUG-4080 · AI 助手把硬字幕 / 只有配音的资源当同等候选推荐给学习
- **报告**：2026-11-04（用户：应用内反馈 nvXct9coD5，Windows）
- **真实性**：✅ 真 bug。AI 操作 `video.discovery.resources` 的路由 `searchResources`（`fushi/lib/src/ops/ctl_video_routes.dart:706`，修复前 662-716）只回 title / size / seeders / resolution / group，不带任何字幕形态 / 配音判定，全靠模型读标题自己判断；操作描述（`fushi/lib/src/ops/op_descriptions_video.dart`）也没提硬字幕 / 配音不适合学习。引擎里已有的判据 `releaseHasBurnedInSubtitles` / `releaseIsDubOnly`（`packages/fushi_engine/lib/media/torrent/video_release_language.dart`，资源选择页「只要原语言」过滤在用）AI 路由没用，「简日内嵌 · 硬字幕」资源被当作同等候选列给用户。
- **[x] ① 已修复** — 新增 `rankVideoResourcesForLearning`：按作品原语言（详情 → `resolveVideoWorkContentLanguage`，与资源搜索页同一条）给每条候选标 `burnedInSubtitles` / `dubOnly` 并排到最后（不剔除）；返回体带 `workLanguage`；操作描述写明学习场景不推荐这两类、优先原语言软字幕资源。
- **[x] ② 已加自动化测试** — `fushi/test/ops/ctl_video_routes_test.dart`（「内嵌」标成硬字幕、English Dub 标成配音，均排在后面，其余保持原序）。
- **备注**：真机验证本轮未做；模型最终是否遵守描述属于提示层，无法用单测覆盖。
