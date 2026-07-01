## BUG-494 · 收藏身份键坍缩致幻影收藏未收藏句被点亮
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug。身份键坍缩。收藏存单 JSON blob（`favorite_sentence_repository.dart:87`）；
  旧身份键 = (text, bookKey, sectionIndex, normCharOffset)（`isFavorited` / `_contentMatch`）。写入
  `normCharOffset = sentenceRange?.offset`（`chrome.part.dart`），无前置查词/选区时为 null → 键
  坍缩 (text, bookKey, sectionIndex, null)；日文重复短句同文本即碰撞 → `isFavorited` 对未收藏句
  误报 true（幻影 ★），`removeByContent` 用 removeWhere 连坐删两条。另发现 id 生成
  `hl_<microsecondsSinceEpoch>` 在同一微秒连续 new 会撞出相同 id（id 身份键亦坍缩）。
- **[x] ① 已修复** — 根因修复（`favorite_sentence_repository.dart`）：① `add` 改**只按 id 去重**
  （不再按内容键 collapse 同章重复短句）；② `removeByContent` 改只删**第一条**匹配（indexWhere +
  removeAt，非 removeWhere 全删），杜绝连坐；③ 新增 `matchedFavoriteId` 返回命中条目精确 id，
  reader 的 `_checkFavoriteStatus`（`lookup.part.dart`）缓存到 `_currentFavoriteId`，收藏 toggle
  取消时走 `removeById(id)` 精确删单条（`chrome.part.dart`）；④ id 生成器 `_generateFavoriteId`
  加进程内单调计数器后缀，保证同微秒也唯一。向后兼容旧无 id 记录（`fromJson` 已补 id）。
  提交 9d2bd1d7f。
- **[x] ② 已加自动化测试** — 纯 Dart 单测
  `hibiki/test/media/audiobook/favorite_sentence_identity_test.dart`（两条同 text/同 section、
  normCharOffset 均 null：断言 add 保留两条独立记录、removeById 精确删单条不连坐、
  matchedFavoriteId 命中返回 id、isFavorited 无幻影）。当前修复前会红（键坍缩），修复后绿。
- **备注**：TODO-1053 Bug C。
