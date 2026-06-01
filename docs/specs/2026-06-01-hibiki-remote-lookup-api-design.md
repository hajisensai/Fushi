# Hibiki 互联远端查询 API 设计

> 日期：2026-06-01
> 状态：第一期已实现并通过单元验证
> 范围：当前 `Hibiki 互联` 后端的实时词典查询和 Local Audio 查询

## 1. 背景与目标

Hibiki 目前的词典查询走本机 `AppModel.searchDictionary()` / `HoshiDicts`，Local Audio 查询走 `WordAudioResolver` / `TtsChannel.queryLocalAudio()`。这两类资源都可能很大，让每台设备重复导入同一套词典和本地音频库不是好设计。

目标是在现有 `Hibiki 互联` 通道上增加远端查询 API：客户端查词或取词条音频时，可以向已配置的 Hibiki Server 发起实时查询。这个功能不是同步整库，不复制词典数据库，不把 Local Audio DB 下发到客户端。

默认策略：远端查询默认关闭，用户显式启用后才参与查词和音频解析。

## 2. 非目标

- 不支持 Google Drive、WebDAV、Dropbox、OneDrive、FTP、SFTP 等文件同步后端的实时查询。
- 不新增一套独立设备连接配置；继续复用 Hibiki 互联的 URL 候选列表和 token。
- 不改变现有本地词典、本地音频和普通网络音频源的默认行为。
- 不把远端文件系统路径暴露给客户端。

## 3. 核心判断

值得做。词典和 Local Audio 是大资源，远端实时查询能解决真实重复导入问题。正确做法是给 Hibiki Server 增加小而明确的查询 API，而不是把 WebDAV 文件同步伪装成 RPC，也不是给每个同步后端硬塞实时能力。

最关键的数据边界：

- 词典查询输入是 `searchTerm`、通配符开关和最大词条数，输出是可序列化的 `DictionarySearchResult`，包含 popup 渲染需要的 `popupJson`。
- Local Audio 查询输入是 `expression` 和 `reading`，输出不能是远端文件路径，必须是一个短生命周期的远端音频 URL。
- 远端查询失败只能降级为空结果或继续后续音频源，不能破坏本地查询。

## 4. API 设计

在 `HibikiSyncServer` 现有 HTTP 服务里保留 WebDAV 行为，并增加 `/api/lookup/*` 路由。鉴权继续使用当前 Basic auth token；未授权请求返回 401。

### 4.1 词典查询

`POST /api/lookup/dictionary`

请求体：

```json
{
  "term": "見る",
  "wildcards": false,
  "maximumTerms": 5
}
```

响应体：

```json
{
  "type": "dictionaryResult",
  "result": {
    "searchTerm": "見る",
    "entries": [],
    "popupJson": "..."
  }
}
```

服务端只调用现有词典查询服务，不新增另一套词典引擎。实现时应优先抽出窄接口，例如 `RemoteLookupService.searchDictionary()`，避免让 `HibikiSyncServer` 直接知道太多 `AppModel` 细节。

### 4.2 Local Audio 查询

`POST /api/lookup/audio`

请求体：

```json
{
  "expression": "見る",
  "reading": "みる"
}
```

命中响应：

```json
{
  "type": "audioResult",
  "url": "http://host:port/api/lookup/audio/file?id=...",
  "contentType": "audio/mpeg"
}
```

未命中响应：

```json
{
  "type": "audioResult",
  "url": null
}
```

`GET /api/lookup/audio/file?id=...` 返回实际音频流。`id` 必须是服务端生成的短生命周期 token，映射到最近一次 Local Audio 命中的 blob 或临时文件。客户端不能传 `file` / `source` / 路径让服务端任意读取文件。

## 5. 客户端设计

新增 `HibikiRemoteLookupClient`，职责只做三件事：

1. 从 `SyncRepository` 读取 Hibiki 互联候选 URL 和 token。
2. 复用现有候选地址顺序和 failover 逻辑。
3. 调用 `/api/lookup/dictionary` 和 `/api/lookup/audio`。

远端查询开关放在偏好层，默认 `false`。UI 放在查词设置页，文案类似“使用 Hibiki 互联查询”。新增 i18n key 时必须通过 `tool/i18n_sync.dart`。

词典接入点：

- `AppModel.searchDictionary()` 保持本地优先。
- 本地没有有效结果、远端查询开启、Hibiki 互联配置可用时，再请求远端。
- 远端结果进入普通结果渲染路径，并写入普通查词历史。用户看到的是一次真实查词结果，历史不该因为来源是远端而变成特殊情况。

音频接入点：

- `WordAudioResolver` 增加远端查询能力，但不要把 Hibiki URL 混进普通 `audioSources` 字符串列表。
- 顺序建议为：本机 Local Audio -> 远端 Hibiki Local Audio -> 用户配置的普通网络音频源。
- 远端音频 URL 直接交给现有播放路径，不落盘为永久资源。

## 6. 设置与兼容

新增偏好：

- `remote_lookup_enabled`: 默认 `false`。

后续如果需要拆分，可以再加：

- `remote_dictionary_lookup_enabled`
- `remote_audio_lookup_enabled`

但第一版不要过早拆分。一个总开关足够，少一个特殊情况就少一个坑。

兼容要求：

- 未配置 Hibiki 互联时，开启开关也不能影响本地查词。
- 远端设备离线、认证失败、超时或版本不支持 API 时，本地查询必须照旧。
- 旧 Hibiki Server 没有 `/api/lookup/*` 时，客户端把 404/405 当作远端不可用，不报致命错误。

## 7. 安全边界

当前 Hibiki Server 是受信任网络上的 HTTP + Basic auth。远端查询继续沿用这个安全模型，但必须遵守以下边界：

- API 只能在 server 开启后可用。
- 所有 `/api/lookup/*` 路径必须鉴权。
- 音频文件接口只接受服务端签发的短生命周期 id。
- 不允许用请求参数读取任意文件。
- 日志不要记录完整 token，不要记录大段词典结果。

## 8. 验证策略

静态和单元测试：

- `HibikiSyncServer`：未授权返回 401；词典 API 调用注入的查询服务；audio API 不暴露路径；旧 WebDAV 路径不受影响。
- `HibikiRemoteLookupClient`：候选 URL failover、401 停止重试、404 视为不支持、超时降级。
- `WordAudioResolver`：本地 Local Audio 优先于远端，远端优先于普通网络源，全部失败返回 null。

集成测试：

- 启动真实 `HibikiSyncServer` 和真实 `HibikiRemoteLookupClient`，用 loopback 完成一次远端词典查询。
- 用 fake Local Audio service 验证远端 audio URL 可播放/可请求。

手工验证：

- 设备 A 导入词典和 Local Audio，开启 Hibiki Server。
- 设备 B 不导入词典和 Local Audio，只配置 Hibiki 互联并开启远端查询。
- 在设备 B 查词能看到设备 A 的词典结果。
- 在设备 B 播放词条音频能命中设备 A 的 Local Audio。
- 关闭远端查询后，设备 B 回到纯本地行为。

## 9. 分期

第一期：

- 增加 server API、client、查词设置页 UI 总开关。
- 本地未命中时远端词典查询。
- `WordAudioResolver` 支持远端音频查询。
- 完成单元测试和 loopback 集成测试。

实现记录：

- `HibikiSyncServer` 已增加 `/api/lookup/dictionary`、`/api/lookup/audio` 和受鉴权的 `/api/lookup/audio/file?id=...`。
- `HibikiRemoteLookupClient` 已复用 `SyncRepository` 中的 Hibiki 互联候选 URL 和 token，并覆盖 failover、401 停止重试、404/405 降级。
- `remote_lookup_enabled` 默认关闭，查词设置页提供总开关。
- `AppModel.searchDictionary()` 保持本地优先，本地无结果时才调用远端；服务端查询显式禁用远端 fallback，避免设备间递归查询。
- `WordAudioResolver` 按本机 Local Audio -> 远端 Hibiki Local Audio -> 普通网络音源顺序解析，不把 Hibiki 远端 URL 写入普通 `audioSources`。
- 当前已验证：`flutter analyze`；`flutter test test/sync/hibiki_sync_server_test.dart test/sync/hibiki_remote_lookup_client_test.dart test/utils/misc/word_audio_resolver_test.dart test/models/preferences_repository_test.dart test/pages/base_source_page_hot_popup_test.dart test/pages/popup_dictionary_page_test.dart`。

第二期：

- 错误可见性优化。
- 远端结果来源标记。
- 如有真实需求，再拆分词典/音频两个独立开关。

## 10. 决策记录

| 决策 | 选择 |
| --- | --- |
| 总方案 | 方案 B：在现有 Hibiki Server 上加专用查询 API |
| 默认行为 | 远端查询默认关闭 |
| 连接配置 | 复用当前 Hibiki 互联 URL/token |
| 本地/远端顺序 | 本地优先，远端作为 fallback |
| 音频返回方式 | 返回受鉴权的短生命周期远端音频 URL，不返回文件路径 |
