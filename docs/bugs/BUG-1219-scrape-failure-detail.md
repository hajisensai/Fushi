## BUG-1219 · 封面刮削失败只给一句笼统提示，完整报错被吞到错误日志
- **报告**：2026-07-28（用户：两张截图，视频「为『Yani Neko』匹配封面」弹窗 Bangumi / TMDB 两个源都只显示「搜索失败，点『搜索』可重试。/ 没能从封面源取到有效响应，请检查网络后重试。」，追问「完整的报错呢」）
- **真实性**：✅ 真 bug（信息丢失，非功能崩溃）。根因不在网络层——底层异常本身就带完整因果链，是 UI 层把它折没了：
  - `hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:203`（原 `_failureReason`）只读 `ScrapeNetworkException.statusCode`，按「有没有状态码」二分成两句固定文案，`message` 字段整个丢弃。
  - `hibiki/lib/src/media/metadata/book_cover_scrape_dialog.dart:106` 书籍侧同款写法，同样丢。
  - 原始异常只经 `ErrorLogService.instance.log('CoverMatchDialog.search', e, stack)` 落错误日志页——用户要换页翻日志才能区分 DNS 不通 / 代理没生效 / 被限流 / 对面 5xx。
  - 底层其实已经把完整链拼好了：`bangumi_api_client.dart:180` `BangumiTransportException('request failed: $e')` 把 `SocketException` 全文带上，`bangumi_client.dart:60` 再包成 `ScrapeNetworkException`，`toString()` 即 `ScrapeNetworkException: Bangumi search request failed: ClientException with SocketException: Failed host lookup: 'api.bgm.tv'`。TMDB 侧（`tmdb_client.dart:58-88`）同样带 message。信息一路到 UI 才被丢。
  - 这是 BUG-1176「失败要有出口」的过度收敛：当时把「可行动原因」做对了，但把技术详情一并挡在了界面外。
- **[x] ① 已修复** — 新增共享展示件 `hibiki/lib/src/media/metadata/scrape_failure_view.dart`（`ScrapeFailureView`）：一句可行动原因（保留原折叠规则）+ **默认折叠**的完整异常 `toString()`，一键「显示详情」展开（限高 132 可滚、`SelectableText` 可选中）+ 「复制错误」按钮。视频封面匹配弹窗与书籍封面刮削弹窗共用这一份——两处此前是逐字重复的两段 `Column`，各改各的必然漂开。两侧各自的标题与 `_failureReason` 原样保留，收口没有抹掉任何一方独有行为。
  - **默认折叠而非常驻展开**（审查决定）：用户诉求是「完整的报错呢」= 要**能看到**，不是每次先撞一段英文。折叠 + 一键展开两者都满足。新增 i18n key `scrape_failure_detail_show` / `scrape_failure_detail_hide`（走 `i18n_sync`，17 语言齐全）。
  - 🔴 **审查发现并一并修掉的凭据泄露**：`TmdbClient` 是 key-in-query（`tmdb_client.dart:44-49` 把 `api_key` 放进 URL），而 `package:http` 的 `ClientException.toString()` 是 `'ClientException: $message, uri=$uri'`（`http-1.6.0/lib/src/exception.dart:15-17`；`io_client.dart:227` 把 `request.url` 整个塞进异常）。于是一次 DNS 失败就把**用户的 TMDB API key** 拼进异常文本，而这串文本同时流向**三条路**：① 弹窗失败态（可选中 + 一键复制 → 截图/粘贴求助即泄露）；② `ErrorLogService.log` 存 `error.toString()`（`error_log_service.dart:386`）零脱敏并落盘；③ 日志上传（`log_uploader.dart` 上传前同样不脱敏）。②③ 在本 PR 之前就已存在，本 PR 把它升级成「摆在屏幕上」。
    修法在**异常构造侧**收口（新增 `hibiki/lib/src/media/metadata/credential_redaction.dart` 的 `redactCredentialsInText`，`tmdb_client.dart` 抛异常前调用）：抛出去的 message 本身就不含凭据，三条路一次修好；只在 UI 层挡等于留着日志与上传继续漏。保留参数名 `api_key=<redacted>` 与主机名，排查信息不丢。
    **全仓扫过**其余出站 client：Bangumi（`bangumi_api_client.dart:199`）、Jimaku（`jimaku_client.dart:265`）、Dropbox 均走 `Authorization` header，qBittorrent 密码走 POST body（`qbittorrent_client.dart:117`）——**均不进 query，不受此路径影响**；TMDB 是唯一一个 key-in-query 的源。
  - 第三个源**离线库**（`ScrapeSource.offlineDb` → `offline_index.dart` 的 `FormatException`）也走同一失败态，已补测试覆盖。
- **[x] ② 已加自动化测试** — widget 行为层 + 纯函数层：
  - `hibiki/test/media/video/scraper/cover_match_dialog_test.dart`：`BUG-1219 搜索失败在弹窗内直出完整技术详情 + 可复制`（先断言**默认折叠**——无 `SelectableText`、无「复制错误」、有「显示详情」；点开后断言界面上存在同时含 `ScrapeNetworkException` 与 `api.bgm.tv` 的 `SelectableText`）、`BUG-1219 带状态码的失败同样直出完整详情（含状态码）`、`BUG-1219 离线库源失败同样能展开出完整详情`。
  - `hibiki/test/media/metadata/book_cover_scrape_dialog_test.dart`：同款两条（主机名 / HTTP 500 状态码），同样先验折叠再验展开。
  - 🔴 `hibiki/test/media/metadata/credential_redaction_test.dart`：**跑真实 `TmdbClient`**（MockClient 复刻 `IOClient` 在 DNS 失败时的真实抛法）断言抛出的异常文本**不含 api_key 值**、但保留 `api_key=<redacted>` 与主机名；另有纯函数用例覆盖多种凭据参数、引号/括号/空白终止符、空值与无 query 文本。
  - **变异实测**（先用 `git diff` 实证变异确已落盘）：① 去掉 `redactCredentialsInText` 调用（`grep` 确认调用数归 0）→ 凭据守卫**转红 1 条**，失败信息里直接打出泄露的完整 URL；② 把 `_detailShown` 初值改回 `true`（退回常驻展开）→ **转红 5 条**（视频 3 + 书籍 2）。不是假绿。
- **真机**：[ ] 未验 —— 复现需断网或让 host 解析失败，本轮只有单测层可执行实证（含凭据泄露的实证），**没有跑过真 app**。
- **备注**：只改「显示」不改「分类」——`_failureReason` 的网络/服务端二分规则原样保留（它是对的）。截图里 Bangumi 与 TMDB 双源同时失败，落在无状态码那一支，真实原因需用户复现后看新界面上的详情串；本条只保证「下次报错能看到完整信息」，不预判那次失败本身的成因。另：候选「使用」失败（apply 路径）的 toast 仍只给折叠原因，未纳入本次范围——toast 不适合承载长异常串。
