## BUG-1653 · 填集数再搜后系列列表消失且搜不出结果
- **报告**：2026-08-15（用户实测，原话「选择集数以后没办法选择系列了。而且搜索不出来结果」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
  的 `_search()`：先 `setState` 清空 `_seriesMatches` / `_selectedSeriesId`，再 `await` 一次
  AniList 往返才回填
- **[x] ① 已修复** — commit `9bfe4cdd95`
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_search_identity_test.dart`
  「AniList 这一跳空手而归时，已有的系列列表不被清空」
- **备注**：与 [BUG-1652] / [BUG-1654] 同一批用户实测反馈，同一个对话框。

### 根因

系列列表的显示条件是 `_seriesMatches.length >= 2`，与结果多少无关。问题在**清空与取数的次序**：

```dart
setState(() { _seriesMatches = const []; _selectedSeriesId = null; });  // 先清空
final media = await anilist.searchAnime(query);                          // 再去拿
```

中间只要这一跳没拿到东西，用户就**永久失去**系列选择面：既搜不到，又换不了系列，只能关掉重开。
而 `AniListClient.searchAnime` 是 fail-open 的（网络/非 200/解析失败一律返回空列表，
`anilist_client.dart:277,283-287`），AniList 本身又有限流——连续点几次搜索很容易触发。

叠加 [BUG-1652]：拿不到 anilist_id 就退回文本搜，而预填的是中文译名，于是「搜不出结果」与
「系列没了」同时发生，看起来像是「选了集数导致的」。

### 修复

- 清空只跟着「换了番名」走：新增 `_seriesQuery` 记录当前系列列表对应哪个番名，
  `sameSeriesQuery` 时保留列表与选中项；
- AniList 返回空**不再覆盖**已有列表（空既可能是查无此番，也可能是限流/抖动，后者不该擦掉用户已有的）；
- 已选定系列且番名没变（典型：只改了集数）→ 直接在该系列内重列文件，不再重跑 AniList
  （省一次往返，也少一次限流机会）；
- `debugInitialSeriesMatches` 预置时同步写 `_seriesQuery`，与真实搜索路径保持一致。
