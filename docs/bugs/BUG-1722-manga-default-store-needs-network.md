## BUG-1722 · 默认 keiyoushi 扩展仓库绑死在首次启动能连上 github，手机上永远看不到
- **报告**：2026-08-18（用户：手机上跑 develop 构建，漫画扩展里没有默认的 keiyoushi 仓库）
- **真实性**：✅ 真 bug（**推翻 BUG-1717「未复现 / 用户版本旧」的结论**）。
  根因 `fushi/lib/src/media/manga/mihon/mihon_manager.dart:141`（修复前）——
  `_seedDefaultStore()` 装配默认仓库的方式是直接调 `addStore(kMihonDefaultStoreIndexUrl)`，
  而 `addStore`（同文件 :162）**先 `fetchStore` + `fetchExtensions` 两次联网成功，才
  `upsertMangaExtensionStore` 写行**。于是「默认仓库这行配置存不存在」被绑死在
  「首次启动能不能连上 github.com」上：连不上就一行都不写，扩展页走
  `mihon_extensions_page.dart:495` 的空态，用户看到的是一个空列表，且完全无从知道
  本该有一个默认仓库。

  **实测证据**（本机与用户手机同一网络）：
  ```
  无代理: curl -L https://github.com/keiyoushi/extensions/raw/repo/index.pb
          -> http=000 redirects=0 time=21.05   (连不上)
  经代理: -> http=200 redirects=1 size=101172
          最终 url=https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb
  ```
  `_get` 的超时是 30s（`mihon_extension_store_client.dart:282`），所以真机上是等 30s
  然后 `SocketException` → 种子失败。

  代码里写的「首启断网不置位、下次启动重试」在**长期**连不上的网络下等于永远重试
  不成，用户永远看不到默认仓库——「重试」只对偶发抖动有效，对用户的实际网络无效。

  **排除的其它假设**（都查过，都不是）：
  - ~~用户版本旧~~：种子逻辑 `32aeb9768d`（2026-08-02, versionCode 8977）落 develop，
    显式开关 `3e94ddc3d6`（2026-08-02, versionCode 8978），距用户报告 2026-08-18 已两周。
    （BUG-1717 引的 `fbdd0b4cdd` **不在 develop 上**，只存在于
    `origin/worktree-manga-browse-filter-fix`；它是 `3e94ddc3d6` 的同名孪生。）
  - ~~pref 过早置位导致永不重试~~：`git log -L` 追过 `_seedDefaultStore` 全部历史，
    develop 上**从未**有过「失败也置位」的版本，所以不存在需要一次性修复的错置位人群。
  - ~~UI 过滤掉了~~：`mihon_extensions_page.dart:590` 直接渲染 `manager.stores`，无任何
    平台分支或过滤；:599 本来就把 `lastError` 显示在副标题里。列表空是因为 DB 真的空。
  - ~~不跟随重定向~~：`followRedirects = false`（`mihon_extension_store_client.dart:274`）
    是故意的，:283-315 手动跟随最多 5 跳并逐跳重新校验 scheme，正确。
  - ~~初始化前置步骤抛异常挡住种子~~：`_recoverAbandonedPreview` / `_clearStagedApks`
    都 `on Object` 吞掉，`_refreshStores` 每仓库 try/catch，均不会挡住种子。
- **[x] ① 已修复** — `_seedDefaultStore` 改成**纯本地 DB 写**：不碰网络，直接
  `upsertMangaExtensionStore` 落一行默认仓库配置，落完即置位 pref；并把
  `_initialise` 里的顺序调成 `_seedDefaultStore()` → `_refreshStores()`，让默认仓库
  的目录由**和其它仓库完全相同**的刷新路径去拉。拉失败就走 `_refreshStores` 既有的
  per-store catch 写 `lastError`，UI 照常显示——用户看得见「Keiyoushi + 错误」，而不是
  一个空列表。顺带把 `addStore` 里重复的 max-sortOrder 计算收成 `_nextStoreSortOrder()`。
  消除的特殊情况：种子不再需要自己的 try/catch、不再需要把 `error` 清空、不再有
  第二条「拉仓库目录」的代码路径。
  `fushi/lib/src/media/manga/mihon/mihon_manager.dart`（提交见 PR）
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_default_store_seed_test.dart`
  的「首次启动连不上也照样有默认仓库：行先落地，失败挂在行上，联网后自动补齐目录」
  一例：`_FailingStoreClient` 下断言默认仓库行**存在**、`lastError` 非空、`lastSyncAt`
  为空、pref 已置位、`error` 为空，随后换 `_FakeStoreClient` 断言目录被补齐、
  `lastError` 清空。已做变异实测：把 `_seedDefaultStore` 退回旧的 `addStore` 形态后
  该例转红，报的正是用户症状 `Actual: []`（仓库列表为空）；还原后 sha256 与变异前一致
  （`78f2c8b6229a7c5e…`）。全目录 `test/media/manga/` 428 例通过。
- **备注**：
  - **存量用户自愈**：受影响人群的 pref 恒为 `false`（旧代码只在成功后置位），所以
    装上新版本后**下次启动自动落行**，不需要任何「重新添加默认仓库」按钮，也不需要
    一次性修复迁移。用户主动删除的人群 pref 为 `true`，照旧不会被复活。
  - 与 BUG-1717 是同一个用户报告：BUG-1717（在 PR#893 分支 `todo-2932-manga-ext-mgmt`
    上）判为「未复现，用户版本旧」，结论有误——它只核到「develop 里有这段代码」，
    没核到「这段代码在用户网络下跑不通」。本条为准。
  - 默认仓库地址 `https://github.com/keiyoushi/extensions/raw/repo/index.pb` 在国内
    移动网络下本来就常年不可达，这是产品层面的已知约束；本 bug 只负责让「默认仓库
    存在且失败可见」，不负责让它一定拉得到。
