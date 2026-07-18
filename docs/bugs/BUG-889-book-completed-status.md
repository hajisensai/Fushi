## BUG-889 · 书/有声书无「已读完」状态·概览 Completed 恒 0·无手动标记入口
- **报告**：2026-07-18（用户：书概览显示「Read 100%」且已打 Finished 标签，书库概览统计仍 Reading:2 / Completed:0）
- **真实性**：✅ 真 bug / 设计缺失。三个正交事实：
  1. **完成状态无持久化载体**：EPUB / 有声书均无「完成」列，书库概览的 `Completed` 由 `tallyShelfProgress`（`hibiki/lib/src/media/collections/shelf_sort.dart`）**每帧从进度临时派生**（`position >= duration` 才计读完），不落库、无手动入口。全库唯一持久完成列是 `VideoBooks.completedAt`（仅视频）。
  2. **显示与判定阈值不一致**：hero「Read x%」用 `.round()`（99.6% 即显示 100%），进度条用 `>0.97` 显满，而统计判定用精确 `position >= duration`——三套阈值。跳过 あとがき/附录的读者进度永远差最后一口，`Completed` 恒不计入。
  3. **有声书完成态无载体**：有声书在书架渲染成 SRT 卡，其完成态需按配对 `bookKey`（阅读会话 `widget.bookKey` 即该 bookKey）记录。
- **[x] ① 已修复** — 单一真值 `EpubBooks.completedAt`（schema v46 增量迁移，镜像 `VideoBooks.completedAt`；有声书共用其配对 bookKey，纯字幕空 bookKey 书本就无进度维度、也打不开阅读，无需另立列）。
  - DB：`setEpubBookCompleted`（手动标记/取消）、`markEpubBookCompletedIfUnset`（读到末尾幂等自动写，不覆盖手动态）、`getCompletedEpubBookKeys`（`database.dart`）。
  - 统计：`tallyShelfProgress` 加 `isCompleted` 判据——标记完成即计读完、不受进度约束、不进在读候选（`shelf_sort.dart`）；概览接入 `_completedBookKeys`（`reader_hibiki_history_page.dart`）。
  - 手动入口：EPUB 书卡 `extraActions` 与有声书 SRT 卡 `_srtExtraActions` 各加「标记为已读完/取消」项，共用 `_toggleBookCompleted`（按 bookKey 写 `EpubBooks.completedAt`）。
  - 自动完成：阅读器 `_persistPosition`（`reader_hibiki/navigation.part.dart`）在最后一章 + 章内进度≥0.999 时 `markEpubBookCompletedIfUnset`（手动翻页与有声书自动推进两条路径的唯一交汇点）。
  - 视觉：完成书进度条恒满格 + 区分色（`_progressBar(item, completed:)`，`card_widgets.part.dart`）。
- **[x] ② 已加自动化测试**：
  - `hibiki/test/database/epub_completed_test.dart`：set/clear、`markEpubBookCompletedIfUnset` 幂等不覆盖、取消后再自动置上、`getCompletedEpubBookKeys` 只返完成书。
  - `hibiki/test/media/shelf_sort_test.dart`：`tallyShelfProgress` 的 `isCompleted` 判据（标记完成计读完、不受进度约束、不进在读候选；null 退回旧行为）。
  - `hibiki/test/database/migration_test.dart`：fresh DB v46 含 `epub_books.completed_at`；全阶梯迁移 `full_ladder_migration_v1_test.dart` 覆盖 v1→v46。
- **备注**：与 BUG-888（标签计数）同一 PR。用户提的「完成时自动挂 Finished 标签」为可选 QoL，本轮未做（默认关、易后加）。真机验收待用户。
