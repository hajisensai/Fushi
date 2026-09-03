## BUG-1711 · 发现页「全部源」透出单个源的目录列表
- **报告**：2026-08-18（用户截图：游戏 → 发现 → 源下拉选「全部源」，正文只有「其他」
  「年份合集」两个文件夹条目）
- **真实性**：✅ 真 bug。那两个文件夹不是聚合结果，是 `alist.erogame.space` **根目录**的
  `/api/fs/list` 返回值——「全部源」在空搜索框下退化成了 AList 单源的目录浏览，而且界面
  上没有任何东西告诉用户这是哪个源。

  根因链：
  1. `fushi/lib/src/pages/implementations/media_discovery_page.dart:96-97` 把「搜索框为空」
     直接解释成「目录浏览」（`final bool browsing = query.isEmpty;`），并在
     `:80-85` 的首帧回调里无条件发这个请求。
  2. `fushi/lib/src/media/discovery/media_discovery_service.dart:116-126` 聚合分支在
     非搜索请求时按 `supportsBrowse` 筛候选源。游戏域三个源里只有 `alist-erogame`
     声明 `supportsBrowse: true`（`sources/alist_discovery_source.dart:56-60`）；
     `sukebei`（`sources/nyaa_discovery_source.dart:44-47`）与 `shinnku`
     （`sources/shinnku_discovery_source.dart:51-53`）都只支持关键词搜索，`supportsBrowse`
     取 `DiscoveryCapabilities` 的默认 false（`discovery_models.dart:168`），且 `sukebei`
     还在默认禁用集里（`preferences_repository.dart` 的 `discoveryDisabledSources`
     默认值 `'sukebei'`）。于是 `candidates.length == 1`，「聚合」名存实亡。
  3. 服务层本来就写明「深层目录路径是源内语义，聚合无意义，必须指定 sourceId」
     （`media_discovery_service.dart:103-107` 的 `ArgumentError` 守卫），但**根目录浏览
     同样是源内语义**，这道守卫漏了 `path == null` 的根浏览，把矛盾留给了 UI。
  4. 界面还有两处让用户无从察觉：`media_discovery_page.dart:409-414` 目录条目不带来源名
     （资源条目走 `_subtitleFor` 才有），`:175-182` 的 `_openFolder` 会隐式把 `_sourceId`
     切成 `folder.sourceId`，而 `:289-291` 的 `DropdownMenu` 用的是 `initialSelection`
     （只在初次构建生效），下拉继续显示「全部源」。
  5. 同一根因在书域是另一种症状：novel/audiobook 没有任何 browse-capable 源，
     `home_reader_page.dart:47` 的发现页一进去就是「无结果」。

- **[x] ① 已修复**（commit `237fac6d2a`）— 消除「空查询 = 目录浏览」这个特殊情况，而不是给聚合结果打补丁：
  1. `media_discovery_service.dart` 的 `load` 把契约从「深层路径必须指定源」收紧成
     **「聚合模式只做搜索」**（`sourceId == null && !request.isSearch` 直接
     `ArgumentError`）；聚合候选筛选随之只剩 `supportsSearch` 一条判据，那个
     `request.isSearch ? supportsSearch : supportsBrowse` 三元本身就是退化的载体。
  2. `media_discovery_page.dart` 按 `_DiscoveryIdle{none, pickSource, queryRequired}`
     三态分流：「全部来源」+ 空查询**一个请求都不发**，正文改成来源清单让用户先选
     （`_buildSourcePicker`）；单源 + 空查询但该源只支持搜索时提示要关键词，同样不发
     请求（否则只会换回一块 unsupported 牌坊）。书域「一进发现页就是无结果」同一处修好。
  3. 目录条目补来源名副标题；头部换成共享的 `DiscoveryHeaderControls`，其中
     `KeyedSubtree(key: ValueKey(selectedSourceId))` 修掉「点进目录隐式切源、下拉还
     显示全部来源」。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/discovery/media_discovery_service_test.dart`：聚合 + 非搜索抛
  `ArgumentError` 且**一个源都没被调到**（假源计调用次数）。
  `fushi/test/pages/media_discovery_page_test.dart`（新）：注入假 `AppModel` + 两个
  记调用次数的假源，四条用例断言真行为——「全部来源」空查询时 `browseCalls == 0` /
  列出来源、只支持搜索的源被选中时仍 `searchCalls == 0`、选目录型源才真发 browse 且
  条目带来源名、头部同时有来源下拉与搜索框。三轮变异实测（还原旧守卫 / 拦截改
  `if (false)` / 删 pickSource 分支与副标题）均能让对应用例变红，还原后逐字节一致。
- **备注**：与 BUG-1710（漫画两个「发现」tab）同一轮发现页整合（TODO-2931）。
