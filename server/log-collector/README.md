# hibiki-log-collector

## 1. 简介

Hibiki app 报错日志上传的接收端：部署在自有 Linux 服务器、前挂腾讯 EdgeOne 反代，对上传的日志**只当哑字节存取、绝不执行/解释**（写盘、原样读回，无任何 eval / 反序列化 / exec）。

## 2. 构建

仅依赖 Go 标准库，零第三方依赖，编译产物是单文件静态二进制。

```bash
cd server/log-collector && go build -o hibiki-log-collector .
```

交叉编译到 Linux（在 Windows/macOS 上为目标服务器出包）：

```bash
GOOS=linux GOARCH=amd64 go build -o hibiki-log-collector .
```

## 3. 环境变量

所有配置从环境变量注入，**绝不写进源码/仓库**。`EO_SECRET` / `UPLOAD_TOKEN` / `BASIC_USER` / `BASIC_PASS` 四个密钥**任一为空都会拒绝启动**（fail-closed，stderr 打印 `refusing to start: missing required secrets: ...` 并 `exit 1`），因为空值会让鉴权 / 防绕过门 fail-open。

| 变量名 | 是否必填 | 默认值 | 说明 |
|---|---|---|---|
| `EO_SECRET` | **必填**（空则拒绝启动） | 无 | EdgeOne 回源时注入的共享密钥，源站靠它拒裸连绕过 EO（`POST /api/logs` 校验 `X-EO-Secret` 头，常数时间比较，不匹配返回 403）。 |
| `UPLOAD_TOKEN` | **必填**（空则拒绝启动） | 无 | App 内置的弱上传凭据（`POST /api/logs` 校验 `X-Upload-Token` 头，不匹配返回 401）。 |
| `BASIC_USER` | **必填**（空则拒绝启动） | 无 | 查看页 HTTP Basic Auth 用户名。 |
| `BASIC_PASS` | **必填**（空则拒绝启动） | 无 | 查看页 HTTP Basic Auth 密码（常数时间比较）。 |
| `DATA_DIR` | 可选 | `/var/lib/hibiki-logs/data` | 日志落盘目录（不存在时自动以 0750 创建）。 |
| `MAX_BODY_BYTES` | 可选 | `1048576`（1<<20 = 1 MB） | 单次上传体上限，超出返回 413。 |
| `RETAIN` | 可选 | `2000` | 保留最近多少条日志，超出按时间删最旧的（≤0 时不清理）。 |
| `LISTEN_ADDR` | 可选 | `127.0.0.1:8787` | 监听地址。**务必只监听本机**，由前置 EO / 反代回源，不要直接暴露公网。 |

> 四个密钥必须是高熵随机值，生成示例：
>
> ```bash
> openssl rand -hex 32
> ```

### 路由一览

| 路由 | 鉴权 | 说明 |
|---|---|---|
| `POST /api/logs` | `X-EO-Secret` + `X-Upload-Token` 头 | 收日志：服务端生成文件名落盘 `<DATA_DIR>/<YYYYMMDD-HHMMSS>-<platform>-<rand6>.txt`，返回 `{"id": "..."}`。 |
| `GET /` | HTTP Basic Auth | 日志列表（时间倒序，文件名 HTML 转义）。 |
| `GET /log/<id>` | HTTP Basic Auth | 看单条日志，`id` 过白名单正则后以 `text/plain; charset=utf-8` 原样返回。 |

## 4. 部署步骤（Linux）

1. 建专用非 root 用户：

   ```bash
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin hibiki-logs
   ```

2. 建数据目录并授权给该用户：

   ```bash
   sudo mkdir -p /var/lib/hibiki-logs/data
   sudo chown -R hibiki-logs:hibiki-logs /var/lib/hibiki-logs
   ```

3. 放二进制：

   ```bash
   sudo cp hibiki-log-collector /usr/local/bin/
   ```

4. 写密钥环境文件 `/etc/hibiki-logs.env`（owner root，chmod 600，**不入库**）。示例内容：

   ```ini
   # 四个密钥必填，用 `openssl rand -hex 32` 生成高熵随机值
   EO_SECRET=替换为高熵随机值
   UPLOAD_TOKEN=替换为高熵随机值
   BASIC_USER=替换为查看页用户名
   BASIC_PASS=替换为高熵随机值
   # 以下为可选项（不写则用默认值）
   # DATA_DIR=/var/lib/hibiki-logs/data
   # MAX_BODY_BYTES=1048576
   # RETAIN=2000
   # LISTEN_ADDR=127.0.0.1:8787
   ```

   收紧权限：

   ```bash
   sudo chmod 600 /etc/hibiki-logs.env
   sudo chown root:root /etc/hibiki-logs.env
   ```

5. 装 systemd 单元并启动：

   ```bash
   sudo cp systemd/hibiki-logs.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now hibiki-logs
   ```

6. 查状态 / 日志：

   ```bash
   systemctl status hibiki-logs
   journalctl -u hibiki-logs
   ```

   若四个密钥没设全，启动失败，`journalctl` 里会看到 `refusing to start: missing required secrets: ...`。

## 5. EdgeOne 控制台配置

源站只监听本机，所有外部流量必须经 EdgeOne 回源，控制台需配：

- **源站指向**：加速域名的源站指向你的服务器。建议源站前置 nginx / caddy，把 EO 回源 TLS 终结后转发到 `127.0.0.1:8787`；或使用 EO 私有 / 安全回源。
- **回源注入自定义头** `X-EO-Secret: <与 env 的 EO_SECRET 同值>`：源站靠它拒裸连——攻击者直怼源站缺该头会被 403 拒绝，无法绕过 EO 的限流 / 限大小。这是防绕过的关键。
- **`POST /api/logs` 速率限制 + 请求体大小上限**：边缘先挡一道，与源站的 `MAX_BODY_BYTES` 呼应（源站超限返回 413）。
- **`GET /`、`GET /log/*` 设不缓存**：这两条路由带 Basic Auth 鉴权内容，必须禁止 EO 缓存，避免缓存泄露。
- **强制 HTTPS**：HTTP Basic Auth 是明文 base64，凭据必须只走 TLS。

## 6. App 端构建注入

App 端的端点与上传 token 经 `--dart-define` 编译期注入（不入库）；不传时 App 不显示上传按钮：

```bash
flutter build apk --release \
  --dart-define=HIBIKI_LOG_ENDPOINT=https://<EO加速域名>/api/logs \
  --dart-define=HIBIKI_LOG_TOKEN=<与 env 的 UPLOAD_TOKEN 同值>
```

## 7. 安全说明

- **只存取不执行**：源站对日志只 `os.WriteFile` / 读回，无 eval / 反序列化为代码 / exec。日志正文一律以 `text/plain; charset=utf-8` 原样返回，浏览器当纯文本，脚本无法执行；列表页所有动态字段经 `html/template` 自动 HTML 转义。响应头钉 `X-Content-Type-Options: nosniff` + `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` + `X-Frame-Options: DENY`。
- **无路径穿越**：文件名完全由服务端生成（绝不用客户端字段拼路径），`GET /log/<id>` 的 id 过白名单正则 `^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$`，带 `..` / `/` 一律拒。
- **App 内 token 可被逆向**：App 是公开二进制，`UPLOAD_TOKEN` 一定能被扒出，无法根治。降险手段是该 token **只授权写日志**（扒走也只能灌日志，读不到、删不掉）；查看密码 `BASIC_USER` / `BASIC_PASS` 只在服务端、不进 App、不进仓库。
- **fail-closed 启动**：四个密钥任一为空都拒绝启动（空值会让鉴权门洞开）；源站只监听本机；systemd 以专用非 root 用户运行，`NoNewPrivileges=yes` / `ProtectSystem=strict` / `ProtectHome=yes` / `PrivateTmp=yes` / `ReadWritePaths` 仅限数据目录 / `CapabilityBoundingSet=` 清空 capabilities，限制爆炸半径。
- **清理**：服务端按 `RETAIN` 滚动删最旧文件防塞盘；查看页只读（无任何状态变更操作，无 CSRF 面），删除走 SSH / 运维。
