# 报错日志上传到服务器 — 设计文档

- 日期：2026-06-06
- 状态：已与用户确认，待 spec review → 实现计划
- 关联代码：`hibiki/lib/src/pages/implementations/error_log_page.dart`、`debug_log_page.dart`、`hibiki/lib/src/utils/misc/log_exporter.dart`

## 1. 背景与目标

当前两个日志页（`ErrorLogPage` / `DebugLogPage`）只能**复制**、**系统分享**、桌面端**另存为**，日志出不了用户设备，开发者无法集中收集线上报错。

目标：在日志页加一个**「上传」**动作，把日志正文 + 设备/版本元信息发到开发者自建的服务器，开发者用一个**带密码的网页**集中查看。

### 非目标（YAGNI）

- 不做自动/后台上传，只在用户**手动点击**时上传（隐私 + 简单）。
- 不做服务端日志检索/聚合/告警，只做「列表 + 点开看原文」。
- 不做网页端删除等状态变更操作（清理靠服务端滚动删旧 / SSH）。
- 不引入云函数 SCF、不引入 COS（用户已有 Linux 常驻服务器，且 SCF 成本高）。

## 2. 架构总览

```
Flutter App ──POST /api/logs (日志正文 + 元信息)──▶ EdgeOne 域名
                                                      │ 反代 / 加速 / 边缘限流 / 限请求体大小
                                                      │ 回源时注入 EO→源站 共享密钥头
                                                      ▼
                                          Linux 服务器：单文件 Go 常驻服务 (systemd)
                                               ├─ 校验密钥头 + 上传 token + body 大小
                                               ├─ 收: 服务端生成文件名落盘 data/<ts>-<plat>-<rand>.txt
                                               └─ 看: GET / → HTTP Basic 密码 → 列表 / GET /log/<id> 原文(text/plain)
```

三层职责：

| 层 | 职责 | 不做什么 |
|---|---|---|
| **App** | 组装元信息 + 日志，POST 到 EO 地址；成功/失败提示 | 不存上传密钥到可读位置以外（见 §5）、不后台上传 |
| **EdgeOne** | 反代回源、加速、**边缘限流 + 限请求体大小**、回源注入共享密钥头、HTTPS 终结 | 不碰存储、不做鉴权逻辑 |
| **Go 源站** | 收（写哑文件）、看（Basic Auth 只读网页） | 不执行/不解释/不反序列化日志内容；不接受裸连（非 EO 直接拒） |

## 3. 数据流与契约

### 3.1 上传请求（App → EO → 源站）

- 方法：`POST /api/logs`
- 头：
  - `Content-Type: application/json; charset=utf-8`
  - `X-Upload-Token: <App 内置上传 token>`（弱凭据，只授权写日志）
  - `X-EO-Secret: <EO 回源注入>`（由 EO 加，App **不**发；源站校验它防裸连绕过 EO）
- Body（JSON）：
  ```json
  {
    "kind": "error" | "debug",
    "app_version": "1.2.3+45",
    "platform": "android|ios|windows|macos|linux",
    "device": "Pixel 7 / Windows 11 ...",
    "ts": "2026-06-06T12:34:56Z",
    "log": "<日志全文，纯文本>"
  }
  ```
- 大小：客户端发送前**截断/拒绝**超限正文；EO 边缘 + 源站再各设一道 body 上限（如 256KB–1MB）。

### 3.2 上传响应（源站 → App）

- 成功：`200` + `{"id": "20260606-123456-android-ab12cd"}`
- 失败：`401`（token/密钥头不对）、`413`（超大）、`429`（限流）、`5xx`（服务端）。响应体为**通用错误**，不回显内部路径/栈。

### 3.3 落盘

- 文件名**完全由源站生成**：`<YYYYMMDD-HHMMSS>-<platform>-<服务端随机短码>.txt`。
- **绝不**用客户端任何字段拼路径（防路径穿越）。元信息作为文件**头部几行**写进文件正文，不进文件名。
- 落盘目录写死（如 `/var/lib/hibiki-logs/data/`）。

### 3.4 查看（开发者浏览器 → EO → 源站）

- `GET /`：HTTP Basic Auth → 列出文件（按时间倒序，显示文件名 + 元信息摘要，**全部 HTML 转义**）。
- `GET /log/<id>`：Basic Auth → id 过白名单正则 + 已知文件集合校验 → 以 `text/plain; charset=utf-8` 原样返回。

## 4. 组件设计

### 4.1 App 端

- **新 helper**：`hibiki/lib/src/utils/misc/log_uploader.dart`
  - `Future<void> uploadLogToServer({required BuildContext context, required String log, required String kind})`，带完整类型签名。
  - 内部：收集 `PackageInfo`（版本）+ 平台 + 设备型号 + UTC 时间 → 组 JSON → 复用项目现有 HTTP 客户端（`http` 包）POST → 按状态码弹对应 SnackBar。
  - 大小保护：超过阈值在客户端先截断并提示。
- **配置（`--dart-define` 编译期注入，已落地方案）**：
  - 入库文件 `hibiki/lib/src/utils/misc/log_upload_config.dart`，`kLogUploadEndpoint` / `kLogUploadToken` 用 `String.fromEnvironment('HIBIKI_LOG_ENDPOINT' / 'HIBIKI_LOG_TOKEN')`，无注入时为空串。
  - 真实值在构建时注入、不入库：`flutter build ... --dart-define=HIBIKI_LOG_ENDPOINT=https://<EO域名>/api/logs --dart-define=HIBIKI_LOG_TOKEN=<token>`。
  - **未配置（空串）时，「上传」按钮自动隐藏**（`bool get showUploadLogAction`），保证 fresh clone 能编译、不暴露端点。
  - 注：此处不采用 `google_oauth_secret` 的「gitignored 文件 + example 模板」范式——那种被 import 的 gitignored 文件在 fresh clone 上会因缺文件而编译失败；`--dart-define` 让配置文件可入库、空值隐藏按钮、clone 即编译，消除该编译特例。
- **UI 接入**：在 `ErrorLogPage` / `DebugLogPage` 工具栏复制/分享按钮旁加 `HibikiIconButton`（云上传图标），**全平台显示**（区别于「另存为」仅桌面）。
- **i18n**：用 `hibiki/tool/i18n_sync.dart --add` 增 key（上传中 / 成功(含 id) / 失败 / 超大），17 语言；`dart run slang` 重生成。

### 4.2 Go 源站（单文件静态二进制）

- 仓库内位置：`server/log-collector/`（Go module + `main.go` + `systemd/hibiki-logs.service` + `README.md` 部署说明 + EO 配置说明）。
- 仅用标准库（`net/http` + `crypto/subtle` 常数时间比较 + `crypto/rand` 生成短码），零第三方依赖 → `go build` 出单文件二进制。
- 配置从**环境变量/配置文件**读：上传 token、Basic Auth 用户名/密码、EO 共享密钥、数据目录、body 上限、保留数量。**绝不写进源码/仓库**。
- 滚动清理：超过保留数量删最旧文件（防塞盘），可选磁盘水位保护。

### 4.3 EdgeOne 配置（文档化，非代码）

`server/log-collector/README.md` 写明控制台要配：源站地址 + 回源 Host、`POST /api/logs` 限流规则、回源注入 `X-EO-Secret`、`GET /` 不缓存、HTTPS 强制。

## 5. 安全硬约束（实现 + 代码审查逐条卡）

核心原则：**源站对日志内容「只当哑字节存取，绝不解释/执行」**，消除「可信 vs 恶意日志」的特殊情况——所有上传一律按不可信哑数据处理。

1. **不执行输入**：源站只 `os.WriteFile` / 读回，**无** `eval` / 反序列化为代码 / `os/exec` / SQL。日志正文永远是死字符串。
2. **防存储型 XSS**：查看页日志正文只用 `text/plain; charset=utf-8` 原样返回；HTML 列表页所有动态字段 HTML 转义；响应头 `X-Content-Type-Options: nosniff` + `Content-Security-Policy: default-src 'none'`。
3. **防路径穿越**：文件名服务端生成；`GET /log/<id>` 的 id 过白名单正则 `^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$` 且只在已知文件集合内查；带 `..`/`/` 一律拒。
4. **鉴权**：查看端 HTTP Basic Auth，密码 `crypto/subtle.ConstantTimeCompare`；强制 HTTPS（EO 终结 TLS）；凭据只在服务端配置，不进 App、不进仓库。
5. **防绕过 EO**：源站校验 `X-EO-Secret`（EO 回源注入），裸连源站缺该头直接 `403` → 攻击者无法跳过 EO 的限流/限大小。
6. **限流 + 限大小 + 配额**：EO 边缘限流 + body 上限；源站再设 body 上限 + 滚动删旧 + （可选）磁盘水位保护。
7. **只读查看页**：网页无任何状态变更操作 → 无 CSRF 面；`X-Frame-Options: DENY` + CSP `frame-ancestors 'none'` 防点击劫持。
8. **最小权限运行**：systemd 跑专用非 root 用户 + `NoNewPrivileges=yes` / `ProtectSystem=strict` / `ReadWritePaths=<数据目录>` / `PrivateTmp=yes` / `ProtectHome=yes`，限制爆炸半径。
9. **不泄露**：统一通用错误响应，不回显内部路径/栈。

### App 端密钥的诚实风险说明

App 是公开二进制，内置的 `kLogUploadToken` **一定能被逆向扒出**，无法根治。降险：该 token **只授权写日志**（扒走也只能灌日志，不能读/删）+ EO 限流限大小 + 源站配额。查看端密码不进 App，安全。

## 6. 测试策略

- **App 端**：
  - `showUploadLogAction` 纯函数门控测试（未配置→false，配置后→true）。
  - 上传 helper 行为测试：mock HTTP，断言请求体含正确元信息、超大截断、各状态码→对应 SnackBar 文案。
  - 源码扫描守卫：`log_upload_config.dart` 在 .gitignore；模板占位符不触发硬编码守卫；i18n key 17 语言齐。
- **Go 源站**（`server/log-collector/` 下 `*_test.go`）：
  - 路径穿越：`GET /log/../../etc/passwd` → 拒。
  - XSS：上传含 `<script>` → 查看返回 `text/plain` 且头含 nosniff（断言不以 text/html 返回）。
  - 鉴权：无/错 Basic Auth → 401；无 `X-EO-Secret` → 403；错 token → 401。
  - 大小：超 body 上限 → 413。
  - 文件名：客户端传恶意 `device`/`platform` 不影响落盘路径（落在数据目录内、名由服务端生成）。
  - 滚动清理：超保留数删最旧。
- 全部 App 改动跑 `dart format .` + `flutter test`；Go 改动跑 `go test ./...`。

## 7. 影响范围与向后兼容

- App 端纯新增（两按钮 + 新 helper + 新配置文件 + i18n key），不改现有复制/分享/另存为路径。
- 未配置端点时按钮隐藏 → 对未配置者**零行为变化**，clone 即可编译。
- 新增 `server/` 目录不影响 Flutter 构建。

## 8. 待实现顺序（交由 writing-plans 细化）

1. App：配置文件模板 + .gitignore + 门控 getter（红→绿）。
2. App：`log_uploader.dart` helper + i18n key + 两页接按钮（行为测试）。
3. Go 源站：`main.go` 收 + 看 + 全部安全约束（`*_test.go`）。
4. systemd unit + README（部署 + EO 配置说明）。
5. 代码审查（opus）：逐条核 §5 安全硬约束。
