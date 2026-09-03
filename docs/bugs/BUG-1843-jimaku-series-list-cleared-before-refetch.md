## BUG-1843 · 填集数再搜后系列列表消失且搜不出结果
- **报告**：2026-08-15（用户实测，原话「选择集数以后没办法选择系列了。而且搜索不出来结果」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
  的 `_search()`：先 `setState` 清空 `_seriesMatches` / `_selectedSeriesId`，再 `await` 一次
  AniList 往返才回填
- **[x] ① 已修复** — 见本轮提交
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_search_identity_test.dart` 的
  「BUG-1843 系列列表不被提前清空」组（3 例）
- **备注**：与 [BUG-1842] / [BUG-1844] / [BUG-1847] 同一批用户实测反馈，同一个对话框。

### 根因

系列列表的显示条件是 `_seriesMatches.length >= 2`，与结果多少无关。问题在**清空与取数的次序**：

```dart
setState(() { _seriesMatches = const []; _selectedSeriesId = null; });  // 先清空
final outcome = await anilist.searchAnime(query);                      // 再去拿
```

中间只要这一跳没拿到东西，用户就**永久失去**系列选择面：既搜不到，又换不了系列，只能关掉重开。
而 AniList 有限流，连续点几次搜索很容易触发 429。

叠加 [BUG-1842]：拿不到 anilist_id 就退回文本搜，而预填的是中文译名，于是「搜不出结果」与
「系列没了」同时发生，看起来像是「选了集数导致的」。

### 修复：把两条判据合成一套

develop 已经有 `AniListSearchOutcome.degraded`（BUG-1782：区分「查无此番」与「没问上」），
本轮补上「换没换番名」。两者**不是两套判据，是同一条链上的两个问题**，各管一段：

| 问题 | 唯一判据 | 行为 |
|---|---|---|
| 这次搜索还是不是同一部番？ | `query == _seriesQuery` | 不同才清空列表 / 选中项 / 降级标记 |
| AniList 这次答案可不可信？ | `!outcome.degraded` | 可信才覆盖 `_seriesMatches` + `_seriesQuery` |

pr955 那版对第二个问题用的是「`media` 非空才替换」——那把「查无此番」和「没问上」混成一个判据：
AniList 明确答「没有这部番」时旧列表会赖着不走，用户对着一批与当前搜索词无关的系列以为还能选。
`degraded` 才是真信号，`media` 空不空只是它的一个副作用。

同时拆开一个被混用的字段（这才是让上面第二条判据原本**不可达**的根因）：

- `_selectedSeriesId` = 当前结果是用哪个 id 搜出来的（chip 高亮用），任何一次检索都会写；
- `_seriesPickedByUser` = 这个 id 是**用户自己点的**，只有 `_selectSeries` 会置真。

只有后者才让搜索「就此打住」（零结果也不回退文本搜）。混成一个字段会让**同一个词搜第二次凭空
变弱**：第一次推断出的 id 被当成用户的选择，把 AniList / 文本回退整条路堵死。

另外：已选定系列且番名没变（典型：只改了集数）→ 直接在该系列内重列文件，不再重跑 AniList
（省一次往返，也少一次限流机会）；`debugInitialSeriesMatches` 预置时同步写 `_seriesQuery`，
与真实搜索路径保持一致。

### 变异实测

1. 把清空改回无条件 → 「填了集数再搜 + AniList 没问上（429）」转红；
2. 把覆盖判据改成 pr955 的 `media.isNotEmpty` → 「AniList 明确答查无此番时列表照常替换」转红；
3. 把 `_selectSeries` 里的 `_seriesPickedByUser = true` 改成 `false` → 「用户手点过的系列在
   同番名重搜时仍然生效」转红。

三次还原后文件 sha256 均与变异前一致。
