## BUG-3366 · video-home-next-up-skips-open-only-episode
- **报告**：2026-10-14（用户：K-ON! 合集看完一集后「继续观看」里没有它，只在「下一集」行显示「下一集 · 第 30 集」）
- **真实性**：✅ 真 bug。本机库 collection 44（59 成员，含 S00 特典穿插）：S02E07 已完成，自动连播进 S02E08 后几秒退出，E08 只有观看时刻、进度 0、未完成。`latestPlayedSeriesIndex`（`fushi/lib/src/media/video/video_home_layout.dart:281`）按 `hasTrace`（含「只有时刻」）把 E08 选为锚点：`continueWatchingSeriesIndex` 因进度 0 返回 null → 整部从「继续观看」消失；`nextEpisodeAfterLatestPlayed` 却跳到 E08 之后的 E09（合集第 30 位）→ E08 在首页无入口。「已更新未看」行（`selectVideoSubscriptionUpdate`）同源，也会跳过 E08。详情页 hero 的 `continueMemberIndex` 对同一状态停在 E08，三处给三个答案。
- **[x] ① 已修复** — `c7fa686cbb`：`latestPlayedSeriesIndex` 跳过「未完成且进度 ≤ 0」的成员，锚点落回上一集，「继续观看」与「下一集」都指向 E08；删掉因此无人使用的 `VideoSeriesPlaybackState.hasTrace`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_home_layout_test.dart`「最近播放那集只有时刻、进度 0 未完成 → 两行都落在它自己」；变异实测：放回旧判据该用例红（latestPlayed 得 1 期望 0），其余 40 条照常。
- **备注**：E08 放了约 17 秒（study_segments 10-13 22:32:39–22:32:56）却存成进度 0，按代码路径看本地存进度没有最小阈值（`video_fushi_page.dart` `_persistPosition` → `updatePosition` 无条件写），不是有意设计；DB 已被今天再次打开覆盖，无法复原当时现场，未单独立案。
