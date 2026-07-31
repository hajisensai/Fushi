## BUG-1318 · 转化后 Bangumi 映射不复核：epub→manga 后进度静默永久停报
- **报告**：2026-08-01（用户：PR#502 阶段二前置审查项④ 的**剩余**部分）
- **真实性**：✅ 真 bug（阶段二接线后必现；今天需要手工改 `format` 才能触发）。

  先澄清：审查项④ 原本的症状「按漫画的话数报了书的章数」**已经修完**，
  由 PR#556（`44116c29d`）+ PR#577 收敛到唯一裁决点
  `resolveBookTrackingLocalProgress`
  （`hibiki/lib/src/media/tracking/media_tracking_repository.dart:107-122`），
  四个上报调用点全部经它按**当前** `BookFormat.isPagedImageBook` 门控，
  两个生产者（即时阅读事件 / 持久化补发）+ 两个消费者（手动关联补发 / 水位对账）
  结构上不会再漂开。本条记的是它**没覆盖**的另一半。

  根因：映射一旦建立就**永不按当前 format 复核**。
  `hibiki/lib/src/media/tracking/media_tracking_service.dart:812-819`
  ```dart
  final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.book, mediaKey: bookKey);
  if (existing != null) return existing;   // ← 命中即原样返回
  ```
  而 `kind`（novel/manga）、`progressMode`（chapter/volume）、`progressOffset`、
  以及 `subjectId`（**按 kind 搜出来的 Bangumi 条目**）全都是建映射当时按 format
  算死的（`media_tracking_service.dart:827-857`）。映射表的唯一键是
  `{provider, mediaType, mediaKey}`（`packages/hibiki_core/lib/src/database/tables.dart:315-317`），
  `kind` 不在身份里，所以转化**不会**分裂出第二条映射 —— 它只会让那唯一一条
  永久保持旧口径。

  后果分两种，都用户可见：
  - **epub → manga**：旧映射是 `progressMode='chapter'`。转化后
    `resolveBookTrackingLocalProgress` 走 `case chapter: return
    format.isPagedImageBook ? null : chapterProgress` → **恒 null → 整条不发**。
    Bangumi 从此再不更新，界面上却仍显示「已连接」，与「从没跑过」同形
    （与 BUG-1220 同一类可见性缺陷）。
  - **manga → epub**：旧映射是 `kind='manga'`、`progressMode='volume'`、
    `progressOffset=<卷号>`、`subjectId=<漫画条目>`。转化后本地已是有章节的文字书，
    却继续按漫画卷号往漫画条目上报；且 `media_tracking_service.dart:662-666` 的
    章节伴随映射要求 `mapping.kind == novel`，故转成书之后也永远不会建章节映射。

- **[ ] ① 未修复** — **需要产品口径拍板**，因为这条会写到**外部服务**：
  转化后应当 (a) 就地重建映射（重新按新 kind 搜条目，可能换成另一个 Bangumi 条目，
  旧条目上已上报的进度留在远端不动）、(b) 解绑并提示用户手动重连、还是
  (c) 保留旧映射但在 UI 明示「口径与当前格式不符，已暂停上报」。
  在拍板前不做代码改动，避免自作主张改远端收藏数据。

- **[ ] ② 未加自动化测试** —

- **备注**：现有 tracking 守卫
  （`hibiki/test/media/tracking/media_tracking_repository_test.dart`、
  `hibiki/test/media/tracking/media_tracking_service_test.dart`）覆盖的是
  「上报值按当前 format 门控」，全部继续绿；它们**测不到**本条，因为本条的问题
  在映射元数据，不在上报值。
