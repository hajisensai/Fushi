## BUG-1707 · Mihon 扩展仓库填 index.min.json 后安装必 404（legacy 分支吞掉 repo.json 的 index_v2）
- **报告**：2026-08-18（用户：手机装漫画扩展报 `MihonRuntimeException(STORE_HTTP_404): Extension store request failed`）
- **真实性**：✅ 真 bug（代码缺陷已复现；**但用户那条报错是否就是这条路径尚未确认**，见备注）。根因 `fushi/lib/src/media/manga/mihon/mihon_extension_store_client.dart:132-152`（修复前）——`fetchStore()` 的两个分支对同一份 `repo.json` 处理不对称：

  - 对象分支（响应首字节 `{`，即用户直接填 `repo.json`）会读 `index_v2` 并递归到新索引；
  - 数组分支（响应首字节 `[`，即用户填 `/index.min.json`）自己又调了一遍 `_parseLegacyStore`，**`index_v2` 整个被忽略**，仓库停在旧格式。

  这不是「少支持一个字段」，是复制出来的第二份解析逻辑必然与第一份漂开。落到用户身上：keiyoushi 已迁到 `index_v2`，它的 `index.min.json` 今天只剩 2 条占位条目（`Outdated App` / `Update to Mihon 0.20.1+`，实测 765 字节），据此按 `base.resolve('apk/<apk>')` 推出的直链 `https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-all.keiyoushi-v1.4.1.apk` 实测 **404**——填这个地址的用户，扩展列表只有两条假条目，点哪条装都是 `STORE_HTTP_404`。

  同一处还有个错配：旧实现把 `index.min.json` 响应的 etag / lastModified 跟 `repo.json` 这个 `indexUrl` 一起落库，下次条件请求发的 etag 压根不属于那个地址。

- **[x] ① 已修复** — 数组分支不再自己解析，直接 `_fetchStore(repo.json)` 递归回对象分支：一份文档一条解析路径，`index_v2` 自动跟随，etag 也自然归属到最终 `indexUrl`。递归改用私有 `_fetchStore(..., required int hop)`，公开 `fetchStore` 签名不变；新增 `_maxIndexHops = 3` 上限——`index_v2` 是仓库方自由填的地址，可以指回 `index.min.json` 形成环，旧对象分支本来就没有任何深度保护，本次改动让这个环更容易触达，必须一起堵。顺带把 `STORE_HTTP_*` 的消息从 `Extension store request failed` 改成带地址（`HTTP 404 for <origin+path>`）：同一个 404 可能是索引没了、扩展列表没了、或 APK 直链指向的 GitHub release 已被上游删除，不写地址只能靠猜（这正是本轮排查的实际困难，配合 [BUG-1703](BUG-1703-manga-extension-error-truncated-toast.md) 的可复制错误对话框才有意义）。地址只留 origin+path：release 资产会 302 到带 `sig=` / `jwt=` 的签名地址，query 原样拼进文案等于把短期凭证写进 UI 和上传的日志。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_extension_store_client_test.dart` 加 3 条：① `follows index_v2 from a legacy index.min.json entry point`（从 `index.min.json` 进入，最终 store 是 v2 索引、apkUrl 来自 v2 而非占位条目）；② `stops an index_v2 loop instead of recursing forever`（`repo.json` 的 `index_v2` 指回 `index.min.json`，断言抛 `TOO_MANY_INDEX_HOPS` 且请求数有界）；③ `names the failing URL without leaking signed query`（404 文案含地址、不含签名 query）。变异实测三发三中，每次还原后源文件 sha256 与变异前逐字节一致（`cc02b9ab…`）：
  - `_maxIndexHops = 3 → 0`：①（和既有的 legacy 用例）由绿转红；
  - `_maxIndexHops = 3 → 30`：② 由绿转红（请求数越界）；
  - `url.replace(query:'',fragment:'') → url`：③ 由绿转红（`SECRET` 泄进文案）。
- **备注**：
  - **未确认的部分（不要当成已定案）**：用户没给仓库地址和扩展名，所以「用户那条 404 就是本条根因」没有证据。本轮实测默认仓库 `https://github.com/keiyoushi/extensions/raw/repo/index.pb` 当前完全正常（302→raw 200，解压 676KB，1368 条 apk 直链抽查 200）。
  - **另一条尚未处理的 404 来源**：keiyoushi 只保留 7 个 release（实测均为 2026-08-16 当天），apk 直链随构建轮换、旧 tag 被删。而 `available` 目录只在内存里、只在冷启动 `_refreshStores()` 时刷新（无缓存表），进程长时间不重启就会拿着已删除的 tag 去下载，同样 `STORE_HTTP_404`。正确形状是安装时以「当次索引」为准而不是快照，本轮**没做**——在用户确认场景前不写投机性的重取重试。
