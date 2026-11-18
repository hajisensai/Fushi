## BUG-4814 · 后台补刮计划失败被吞成空清单：待确认提醒条凭空消失且无日志
- **报告**：2026-11-17（来源：小说 / 漫画 / 视频优化清单复核 video-14，代码审读发现）
- **真实性**：✅ 真 bug。根因（修前行号，基准 `8d58da51da9`）：
  - `packages/fushi_engine/lib/media/video/metadata/video_library_scrape_sweep.dart:678-684`
    `_plannedWorksOrEmpty` 用 `catch (_)` 把计划阶段的任何异常（读库失败、成员文件
    存在性判据抛错、计划器内部异常）吞成一份空的 `_PlannedWorks`，没有日志。
  - 同文件 `:559-561` 紧接着 `_lastPending = planned.pending`：失败得到的空清单
    **覆盖了上一份待确认清单**，并原样返回给视频页（唯一消费方
    `fushi/lib/src/pages/implementations/home_page.dart` 的
    `sweepAndListPending` 调用）。表现：一次瞬时失败就让「有 N 部作品待确认」的
    提醒条消失，而且之后「批次在跑时直接回上一份清单」的快路径回的也是这份空清单。
  - 同文件 `:649-651` 批次的 `catch (_)` 同样不记日志（注释「后台静默批次：单轮
    失败不打扰页面」——不打扰页面是刻意的，但不留痕不是；同文件其余失败点都走
    `engineLog.log`）。
- **[x] ① 已修复** — 计划失败：`engineLog.log('VideoLibraryScrapeSweep.plan', …)`，
  返回上一份 `_lastPending`（不覆盖），本轮不发批次；`_plannedWorksOrEmpty` 删除。
  批次失败：只补 `engineLog.log('VideoLibraryScrapeSweep.batch', …)`，仍不抛、不提示。
  提交见本分支 `pr/video-library-scrape-io`。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`
  「计划 / 批次失败不吞（video-14）」组：计划失败时清单沿用上一份、日志源为
  `VideoLibraryScrapeSweep.plan`、不发批次、恢复后新作品照常进清单并被认领；
  批次抛错时清单照常返回且日志源含 `VideoLibraryScrapeSweep.batch`。
- **备注**：纯后台逻辑，无界面改动、无 i18n、无 schema 变化，不需要设备复测。
  `pendingWorks()` / `ignoredWorks()`（视频页待确认队列的显式读取）保持原行为：
  计划抛错照常上抛给调用方，不在这里吞。
