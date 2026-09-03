## BUG-1705 · qBittorrent 5.2+ 登录成功返回 204 被判成登录失败
- **报告**：2026-08-18（用户：截图 + 上游 issue pennydreadful/bookshelf#160）
- **真实性**：✅ 真 bug，且**波及面比报告更大**（不只是登录）。根因 `fushi/lib/src/media/torrent/qbittorrent_client.dart:347`（旧行：`if (res.statusCode != 200) { … return false; }`）以及同文件另外 7 处硬判 `statusCode == 200` 的动作接口。

  上游根因（对照 qbittorrent/qBittorrent `release-5.1.2` 与 `release-5.2.3` 源码逐版本核实）：
  - `src/webui/api/apicontroller.h`：`RegularAPIResult.data` 是默认构造的 `QVariant`；`setResult(const QString &)` 直接 `m_result.data = result`。传 `QString()`（null QString）时 `QVariant::isNull()` 为真。
  - `src/webui/webapplication.cpp:406`：`if (result.data.isNull()) response.status = {.code = 204};`。**5.1.2 全文没有 204**，这是 5.2 新增的编码。
  - 于是所有「做完了没东西可回」的接口在 5.2 从 `200` + 空 body 变成 **204**：`auth/login`、`torrents/{delete,stop,start,setLocation,renameFile,filePrio,createCategory,recheck}`（后者在 5.2.3 里统一写作 `setResult(QString())`）。
  - `AuthController::loginAction()` 同时把失败编码从 5.1 的 `200` + body `Fails.` 改成 `throw APIError(APIErrorType::Unauthorized)` → **401**。封禁仍是 403 + `…banned…`（移到 `WebApplication::isBanned()`），旧判据可用。
  - `TorrentsController::addAction()` 从 `setResult("Ok.")` 改成返回统计 JSON；磁力链元数据未到手时 `setStatus(APIStatus::Async)` → **202**；一个都没加成功时 `throw APIError(Conflict)` → **409**。旧判据 `200 && body.startsWith('Ok')` 对 5.2 恒为 false。
  - 会话过期路径两版都是 `ForbiddenHTTPError()` → 403，`_request` 的「403 重登一次」逻辑不受影响，未动。

  用户现场表现：qBittorrent 5.2.3 + WebUI `http://127.0.0.1:1236` 正常返回 200，账密地址端口都对，Hibiki 仍报登录失败。

- **[x] ① 已修复** — `fushi/lib/src/media/torrent/qbittorrent_client.dart` 新增三个纯函数协议层，把两代编码差异收在一处，调用点不再各自硬判状态码：
  - `isQbActionSuccess(int)`：200（≤5.1）或 204（≥5.2）都算成功。用于 delete / createCategory / pause·stop / resume·start / renameFile / setLocation / filePrio。
  - `classifyQbLoginFailure(int, String)`：成功返回 null；204 与 `200 Ok.` 都判成功，401 与 `200 Fails.` 都判账密错误，403+banned 单独报。
  - `isQbAddAccepted(int, String)`：吃下 `200 Ok.`（≤5.1）、`200` 统计 JSON 与 `202` pending（≥5.2），全 0 / 409 判失败。
  - 需要解析响应体的查询接口（`torrents/info`、`torrents/files`、`app/version`、`transfer/info`、`app/preferences`、`sync/torrentPeers`、`torrents/{trackers,pieceStates}`）**保持只认 200**——它们收到 204 就是真异常。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/qbittorrent_api_v52_test.dart`（20 条）：三个纯函数的两代编码判读逐条钉死；`MockClient` 仿真 qb 5.2.3 服务器（登录 204+SID、动作接口 204、add 回统计 JSON、旧端点 404 回退）跑端到端；另有 qb 5.1 服务器的回归护栏，确保老服务器没被改坏。
  - 变异实测：把 `isQbActionSuccess` 退回 `statusCode == 200` → 3 条红；还原后文件 sha256 与变异前逐字节一致。
- **备注**：同类问题上游生态已普遍打过补丁（Sonarr `ae18ad61`、Radarr#11339）。本仓只有 `qbittorrent_client.dart` 一处 qB HTTP 实现，已全量覆盖（`grep auth/login` 复核）。用户本机 1236 端口在排查时未启动，无法现场抓包，故改用上游 `release-5.2.3` / `release-5.1.2` 源码逐行比对取证。
