## BUG-2963 · 全部哆啦A梦剧场版被解析成category=movie，作品搜索只剩TMDB直接失败
- **报告**：2026-10-06（本机 fushi_server 第三次实跑「一口气下载全部哆啦A梦剧场版」：第一句话后 5 秒即 `failed: TMDB is not configured`；前两次同一句话都搜到了 4 部候选——AI 输出不稳定）
- **真实性**：✅ 真 bug。意图解析系统提示（`buildVideoAcquisitionIntentSystemPrompt`，`packages/fushi_engine/lib/ai/ai_video_acquisition_assistant.dart`）只给出 `category` 的枚举值、从没说它的语义；而代码里的分类是「媒介」——动画剧场版的 `discoveryCategory` 是 `anime`，MAL / AniList 只声明 anime 类别（`VideoDiscoveryService._supportsRequest` 按类别过滤来源）。AI 把「剧场版」理解成 `category: movie` 时作品搜索只剩 TMDB，服务端没配 TMDB key → 唯一来源失败 → `_searchWorks` 把首个来源失败当结果报出来。AI 与代码之间的契约没定义，输出随机就随机失败。
- **[x] ① 已修复** — 提示词新增 `category` 规则：它是媒介不是形态；日式动画（含动画剧场版 / 特别篇）一律 `anime`，`movie` / `tv` 只用于非动画；「全部 X 剧场版」用 `scope: "movies"` 表达，不是 `category: "movie"`。本机实跑：修后同一句话搜到候选并走完整套清单（「哆啦A梦」15 部，13 部有资源）。
- **[x] ② 已加自动化测试** — `fushi/test/ai/ai_video_acquisition_assistant_test.dart`「BUG-2963 category 是媒介不是形态」（钉住提示词里的契约句）。
- **备注**：提示词约束只能降低、不能消灭 AI 偏离；若后续仍见 `movie`，下一步是在代码侧把类别过滤从「形态」与「媒介」两个维度拆开。
