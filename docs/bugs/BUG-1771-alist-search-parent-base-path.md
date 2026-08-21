## BUG-1771 · AList 搜索结果路径带 base_path 前缀，目录打不开、文件下不了
- **报告**：2026-08-22（修 [BUG-1768](BUG-1768-discovery-folder-infinite-nesting.md) 时在真机上追下去发现：自嵌套修好后，点进 erogame.space 搜索结果里的目录仍然拿不到任何内容）
- **真实性**：✅ 真 bug，已用站点真实 API 逐条实测定性。AList 的 `/api/fs/search` 返回的 `parent` 在**用户根命名空间**里，而 `/api/fs/list` 与 `/api/fs/get` 收的是**相对该根**的路径。`AListDiscoverySource.search()`（`fushi/lib/src/media/discovery/sources/alist_discovery_source.dart`）原样把 `raw['parent']` 交给 `_entryFrom`，于是搜索结果里每个目录的 `DiscoveryFolder.path` 和每个文件的 `DiscoveryResourceItem.id` 都带着前缀，`browse()` 与 `resolvePayload()` 拿去用必然 404。

  alist.erogame.space 实测（2026-08-22，匿名 guest）：

  | 请求 | 结果 |
  |---|---|
  | `GET /api/me` | `base_path = "/guest"`，username `guest` |
  | `fs/search parent:"/" keywords:"WHITE ALBUM2"` | 200，106 条；目录条目的 `parent` = `/guest/其他/エロゲー特典・関連物（全年齢向け作品を含む）/Leaf` |
  | `fs/list "/guest/其他/…/Leaf/WHITE ALBUM2"` | **500 `object not found`** |
  | `fs/list "/其他/…/Leaf/WHITE ALBUM2"` | **200**，含那张 OST rar |
  | `fs/list "/"` | 200，两个目录（`其他` / `年份合集`） |
  | `fs/get` 同一文件带前缀 | 500 `object not found` |
  | `fs/get` 同一文件剥掉前缀 | **200，拿到 `raw_url`** |

  也就是说：**搜索结果里的文件从来就下载不了**，不只是目录打不开。`fs/list` 本身完全正常，一开始误判成「站点 list 接口整体不可用」是因为我把 search 的路径原样喂了进去。
- **[x] ① 已修复** — `AListDiscoverySource` 增加 `_ensureBasePath(sampleParents)` + `_stripBasePath()`：拿到 search 结果后，用**本来就必须能用**的 `fs/list '/'` 取真实根下的第一层名字，在样本 `parent` 的分段里找第一个命中的位置，它**之前**那一段就是前缀（根 `[其他, 年份合集]` + parent `/guest/其他/…` → 前缀 `/guest`）。命中在第 1 段说明两边本来就同命名空间，不剥。结果缓存（`_basePathProbed`）。`parent` 恰好等于前缀时归一成 `/`，不带该前缀的原样返回。**不硬编码 `/guest`**。推断失败（根列不出来、网络抖动、信封变形）一律吞掉并退回不剥前缀的老行为，绝不因为这个附加推断让整个源不可用。`browse()` 不受影响：它的路径本来就产自我们自己从 `/` 开始的列表。

  **为什么不用 `/api/me`**（它直接给 `base_path`，第一版就是这么写的）：本机实测 alist.erogame.space 的 `/api/me` **直连 3/3 连接超时**（各 12s），而同一时刻 `fs/list`、`fs/search`、`/api/public/settings`、首页全部正常。第一版按 `/api/me` 实现后真机复验仍然失败——因为探测超时被吞掉、前缀拿不到、路径照旧带前缀。拿一个可能连不上的端点当前置依赖，结果是每次首搜先白等一个连接超时然后照样没用，比不做还差。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/sources/alist_discovery_source_test.dart` 三条，用一个按 path 分发的 `mockSite` helper：①根名落在第 2 段 → 文件 id 变 `/其他/ATRI.rar`、`parent` 恰为前缀的目录归一成 `/其他`，并断言真的打了 `fs/list`；②根名已在第 1 段（根里真有个目录叫 `guest`）→ 路径**原样**保留 `/guest/其他/ATRI.rar`；③`fs/list` 返回 500 → 退回不剥前缀且搜索照常成功。三条互为反例：只有①会被「一律剥首段」骗过，只有②会被「永不剥」骗过，③钉住「推断失败不许把搜索本身拖挂」。**注意**：原有的 `search:条目路径来自 parent+name` 那条测试其实把 bug 固化成了断言（`expect(item.id, '/guest/其他/ATRI.rar')`），已被②取代并写清了两者的区别。
- **备注**：真机验证 2026-08-22，隔离实例（`FushiDiscProbe` 数据目录 + 独立互斥体 + 独立 WebView2 目录），未碰生产库。
