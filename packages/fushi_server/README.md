# fushi_server — 无头 Fushi 服务端（Linux / Windows / macOS）

`fushi_server` 是 Fushi 的无 GUI 服务端：一个 CLI 进程，跑与桌面 Fushi **同一份**互联
host（`packages/fushi_engine`），带 WebUI。装在 NAS / 家用服务器 / VPS 上，手机和桌面
Fushi 通过「互联」配对后，把这些活丢给它：

| 能力 | 协议 | 说明 |
|---|---|---|
| 媒体库 host（视频 / 书 / 漫画 / 有声书 / 词典包） | `/api/library/*`（冻结面） | 服务端扫描本机目录入库，客户端浏览、拉流、同步进度 |
| 漫画整卷 OCR | `/api/manga_ocr/*` | 客户端上传卷，服务端跑 ONNX 检测+识别，回传 mokuro |
| 字幕识别（ASR） | `/api/jobs`（kind=`asr`） | 客户端上传音轨或指定 host 视频，服务端转录成 SRT + token 时间轴 |
| 代下载 | `/api/downloads` | 内置 libtorrent 引擎或外接 qBittorrent，落 `<data>/documents/downloads` 后自动入库。能力位 `kinds` = `video` / `novel` / `manga` / `audiobook`：非视频整包走引擎发现导入执行器按域入库（小说 EPUB / 文本转 EPUB、漫画 cbz/zip 图包、有声书正文+字幕+音频对齐）。**不收游戏**（服务端没有游戏库，投了 400）；小说包里的 **PDF** 不能导入（要 app 的 pdfrx 栅格化），任务以 `unsupportedOnThisHost` 挡下；cbr / cb7 / rar 需要服务端有 7-Zip（`FUSHI_7ZA` 或 PATH 上的 `7z` / `7za`），否则 `archiveToolMissing` |
| 内容订阅 | `/api/subscriptions` | 订阅在 host 上创建、由 host 周期检查（Nyaa / apibay / Knaben / Torznab）并投进自己的下载管线；客户端发现页可选「运行在 host」 |
| 配置文件（Profile）寄存 | `/api/interconnect/profile`（GET / PUT，仅 TLS） | 设备「互联 → 上传配置」把配置方案推到服务端寄存，另一台设备「下载配置」拉走；服务端只寄存不应用。默认关（`profile_transfer`） |
| WebUI / admin API | `http(s)://<host>:38780/` | 状态、配对 PIN、库根管理、上传、任务、下载、模型、设置、日志 |

设计文档：[`docs/specs/2026-09-08-fushi-server-headless-design.md`](../../docs/specs/2026-09-08-fushi-server-headless-design.md)。

## 安装

从独立发布仓 [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases)
下包（源码在本仓；那边的 `release.yml` 回调本仓 `release-server.yml` 构建；beta 是
prerelease，formal 是 Latest）：`fushi_server-<version>-<seq>-linux-x64.tar.gz` /
`fushi_server-<version>-<seq>-windows-x64.zip`。改到服务端（或它的依赖包 / 随包原生库）的
PR 也在 `build-multiplatform.yml` 的 `linux-server` job 出一份 `fushi_server-linux-x64`
工件（Actions 页面下载）。布局：

```
fushi_server/
  bin/fushi_server            # 可执行文件（Windows 为 .exe）
  lib/libsqlite3.so           # dart build 的 native asset
  lib/libfushi_torrent_ffi.so # 内置 torrent 引擎（Linux 静态链 libtorrent/boost/openssl，零运行库依赖；Windows 为 DLL + 3 个运行时 DLL）
  lib/libonnxruntime.so*      # onnxruntime 1.22.0 CPU 版（OCR / ASR）
  README.md
```

解压到任意目录即可（例 `/opt/fushi_server`）。**目标机运行期依赖**：

- Linux：glibc ≥ 2.35（Debian 12 / Ubuntu 22.04 及以后）。内置 torrent 引擎与 onnxruntime 都随包、静态，不用装 `libtorrent-rasterbar` / `libssl`。
- `ffmpeg` / `ffprobe`：视频封面抽帧、ASR 音轨解码、下载后转封装。不在 PATH 时在配置里写 `ffmpeg:` / `ffprobe:` 路径（直接生效，不需要环境变量；`FUSHI_FFMPEG` 仍认，配置优先）。
- 局域网自动发现（可选）：`avahi-utils`（有 `avahi-publish` 就广播 `_fushi._tcp`；没有也能手输地址配对）。

本机自己构建（任何平台，需 Dart SDK ≥ 3.8）：

```bash
cd packages/fushi_server
dart pub get
dart build cli            # 产物 build/cli/<os>_<arch>/bundle/
```

`dart compile exe` **不行**：sqlite3 是 native asset，只有 `dart build cli` 会把它打进 bundle。

## 快速开始

```bash
cd /opt/fushi_server
bin/fushi_server init                # 生成 fushi_server.yaml（含随机 admin_token）
$EDITOR fushi_server.yaml            # 填 libraries[]
bin/fushi_server serve --scan        # 起服务 + 首次扫描
```

启动后终端打印互联端口、TLS 指纹、WebUI 地址。浏览器开 `https://<host>:38780/`（自签证书，浏览器会警告一次），输入 `admin_token` 登录。

在手机/桌面 Fushi：设置 → 互联 → 添加设备 → 输入 `<host>:38765`。服务端终端与 WebUI「配对」页会显示 6 位 PIN，在 Fushi 里输入即完成配对。

### systemd

```ini
# /etc/systemd/system/fushi_server.service
[Unit]
Description=Fushi headless server
After=network-online.target

[Service]
User=fushi
WorkingDirectory=/opt/fushi_server
ExecStart=/opt/fushi_server/bin/fushi_server serve --config /opt/fushi_server/fushi_server.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## 配置文件 `fushi_server.yaml`

```yaml
data_dir: "data"              # 相对配置文件所在目录；DB / 互联身份 / 任务 / 日志 / 下载都在这
port: 38765                   # 互联协议端口（客户端连这个）
bind: "0.0.0.0"
tls: true                     # 自签证书 + 指纹 TOFU；关掉只在可信内网
device_name: "nas"
lan_requires_pin: true        # 无头进程没有审批弹窗，PIN 是唯一人因；别关
admin_port: 38780             # WebUI / admin API；0 = 关闭
admin_bind: "0.0.0.0"
admin_token: "..."            # init 生成；忘了用 `fushi_server admin reset-token`
subtitle_language: "ja"       # 扫描视频时 sidecar 字幕匹配语言
metadata_locale: "zh-CN"      # 刮削资料语言（BCP-47）：TMDB 文字/海报语言由它派生；偏好表显式设过 video_metadata_locale 时以偏好为准；改了重启生效
scan_scrape: true             # 扫描后自动补刮「从未识别过」的视频作品（见下文「视频刮削」）
# tmdb_api_key: "..."         # TMDB API key。服务端没有 app 的内置 key，不填则 TMDB 不可用；改了重启生效
scan_prune: true              # 扫描后回收「文件已消失」的视频条目（带护栏，见下文）
profile_transfer: false       # 允许已配对设备推送 / 拉取配置文件（Profile，见下文「配置文件寄存」）；默认关，WebUI 可开，保存即生效
# ffmpeg: "/usr/bin/ffmpeg"    # 可执行路径（优先于 FUSHI_FFMPEG 与 PATH）；空 = PATH
# ffprobe: "/usr/bin/ffprobe"
# onnxruntime_library: "/opt/ort-gpu/lib/libonnxruntime.so"   # 换 GPU 版 ORT 时指过去
upload_quota_bytes: 53687091200   # WebUI 上传累计配额（50 GB），防被当网盘
public_urls: []               # 公网 / 反代 / DDNS 地址（如 - "https://nas.example.com"），经 /api/host/addresses 公布给已配对设备自动学习
p2p: false                    # 允许经 iroh P2P 隧道远程连接（无公网 IP 时用；会连 iroh 公共中继与发现服务）。需随包 libfushi_p2p（bin/../lib/ 或 FUSHI_P2P_LIB）
p2p_relays: []                # 自建 iroh-relay 地址；空 = iroh 公共中继
torrent:
  engine: "auto"              # auto | embedded | qbittorrent
  # library: "/opt/fushi_server/lib/libfushi_torrent_ffi.so"   # 缺省找 bundle/lib，再找系统路径
  listen: "0.0.0.0:6881,[::]:6881"
qbittorrent:                  # engine=qbittorrent 或 auto 无内置库时用
  url: "http://127.0.0.1:8080"
  username: "admin"
  password: "..."
ai:                           # 「AI 下视频」助手会话用的 AI 提供商（见下文）；整段省略 = 不用 AI、不发任何 AI 请求
  preset: "openai"            # openai / anthropic / gemini / deepseek / qwen / zhipu / … / custom（全部自填）
  api_key: "sk-..."
  # model: ""                 # 空 = 预设的起点模型
  # base_url: ""              # 空 = 预设地址（custom 必填）
  # protocol: ""              # 空 = 跟随预设：openAiCompatible / anthropicMessages / geminiGenerateContent
  reasoning_effort: "none"    # none / low / medium / high
  allow_insecure_http: false  # 本地推理服务（Ollama / LM Studio）走 http://localhost 时才需要
  web_knowledge: true         # 联网资料（内置维基站）辅助识别作品 / 列系列
libraries:
  - id: "anime"
    path: "/srv/media/anime"
    kind: "video"             # video | book | manga
    enabled: true
  - id: "manga"
    path: "/srv/media/manga"
    kind: "manga"             # .mokuro 卷 + 纯页图目录（根有页图=一卷；否则每个含页图的直接子目录一卷）；cbz/cbr/pdf 暂不支持
    enabled: true
```

WebUI「设置」页改的就是这个文件；端口 / TLS / 绑定 / torrent / qBittorrent / ORT 路径改后要重启 `serve`。

「设置」页的「远程访问」卡片管 `public_urls` / `p2p` / `p2p_relays` 三项，**保存即生效、不用重启**：
公网地址由地址集实时读；打开 P2P 会在正在跑的 host 上起 iroh 端点 + 信任区监听口，关掉则停入站、关监听口、关端点（不再连中继）；
改自建中继会关掉旧端点按新中继重建（NodeId 不变，私钥存在数据目录的偏好表里）。多次快速切换按提交顺序串行执行，以最后一次为准。
没随包 `libfushi_p2p`（`bin/../lib/` 或 `FUSHI_P2P_LIB`）时开关置灰，API 拒绝从关到开（409）；`bind` 只监听本机时隧道不启用。
卡片里显示 P2P 是否生效、本机 NodeId、当前中继与直连地址。

## CLI

```
fushi_server init                      生成配置
fushi_server serve [--scan] [--[no-]prune]   起服务（Ctrl-C / SIGTERM 优雅停）；--no-prune 对本进程所有扫描生效
fushi_server scan [--[no-]prune] [--[no-]scrape]   扫描 libraries[] 入库，随后同步补刮（不起服务）
fushi_server status                    打印库/配对概况
fushi_server pair ls | revoke <peerId> 已配对设备
fushi_server admin reset-token         重生成 admin_token
fushi_server models status | pull <lang|ocr>   模型状态 / 拉取
fushi_server transcribe <media> --lang ja [--cpu]   本地跑一次 ASR（调试）
```

所有子命令接受 `--config <path>`（默认当前目录 `fushi_server.yaml`）和 `--verbose`。

### `ctl`：操作正在运行的 serve

上面的命令都是**离线**的（直接开数据目录）。`serve` 在跑时，用 `ctl` 经下面的 admin API
改它，不碰数据库；扫描进度、下载队列、订阅、模型下载这些运行时状态也只有 `ctl` 看得到。

```
fushi_server ctl status | logs | p2p
fushi_server ctl lib [ls] | add <path> [--kind video|book] [--id x] | rm <id> [--purge]
fushi_server ctl scan [--prune|--no-prune]
fushi_server ctl dl [ls] | add <magnet> --title t [--media-kind movie|tv] | cancel|retry|rm <id>
fushi_server ctl sub [ls] | add '<json>' | check [id] | enable|disable|rm <id>
fushi_server ctl models [ls] | pull <ja|…|ocr|ocr:key>
fushi_server ctl anki [status] | sync | login --user u（密码读 stdin / FUSHI_ANKI_PASSWORD）| …
fushi_server ctl upload <文件…> --lib <id> [--path 目录]   分块断点续传（传完 scan）
fushi_server ctl logs -f                                 跟随日志
fushi_server ctl raw <METHOD> /api/admin/... ['<json>']   直调任意 admin 接口

# 经互联接口（admin 以 host 身份代调 /api/admin/host/*，配对路由除外）
fushi_server ctl books|videos|audiobooks|dict|metadata [ls]
fushi_server ctl books progress <key> [--set '<json>']   videos position|playback <id> …
fushi_server ctl scrape pending | sweep | ai-identify <id> | search <bookUid> -q 词
                  | identify <bookUid> --provider anidb|mal|tmdb --external-id <id>
fushi_server ctl jobs submit asr <音频> -l ja -o out.srt   在运行中的服务上转录
fushi_server ctl assistant start --feature f | show <id> --wait | act <id> '<json>'
fushi_server ctl host <METHOD> <互联路径> ['<json>']       直调任意互联接口
```

地址按配置的 `admin_bind` / `admin_port` / `tls` 推本机地址（通配 bind 换回环），token 读
`admin_token`；TLS 下按数据目录里服务端证书的指纹钉扎。远程用 `--url` / `--token` /
`--fingerprint` 覆盖。`--json` 原样输出。退出码：0 成功、1 服务端拒绝、64 用法错误、
69 连不上、75 冲突（409）、77 鉴权失败。完整动作表见 `fushi_server --help`。

**数据目录互斥**：`serve` 与所有直接打开数据库的离线命令（`scan` / `status` / `import` /
`audiobook` / `dict` …）启动时都要拿 `<data_dir>/fushi_server.lock` 的排他 OS 文件锁（进程退出
自动释放，锁文件里记着持有者 pid 与 WebUI 地址）。serve 运行期间离线命令一律以 **75** 拒绝——
包括看似只读的 `status`：打开运行时就会跑 schema 迁移 / 补写偏好，和 serve 的写事务并发不安全；
运行中请用上面的 `ctl`。第二个 serve、或离线命令正在跑时启动 serve，同样 75。

**`--json` 的 stdout**：只有最终那一个 JSON 文档（Linux / macOS 在 fd 层把后台 isolate 与原生库的
打印整体改道 stderr），可直接 `| jq`；进度与诊断一律在 stderr。

## admin API（WebUI 用的那套）

鉴权：`Authorization: Bearer <admin_token>`，或浏览器 `POST /login`（表单 `token=`）拿 cookie。全部 JSON，前缀 `/api/admin/`：

| 路由 | 说明 |
|---|---|
| `GET status` / `GET logs` | 运行状态、最近 500 行日志 |
| `GET pairing` / `DELETE pairing/peers/<id>` | 待输入 PIN + 已配对列表 / 吊销 |
| `GET|POST libraries` / `DELETE libraries/<id>` / `POST scan` | 库根管理（写回 yaml）/ 触发扫描（单飞） |
| `GET jobs` / `DELETE jobs/<id>` | 互联任务（ASR 等） |
| `GET|POST downloads` / `POST downloads/<id>/cancel|retry` / `DELETE downloads/<id>` | 代下载 |
| `GET|POST subscriptions` / `POST subscriptions/check` / `POST subscriptions/<id>/enable|check` / `DELETE subscriptions/<id>` | 内容订阅（WebUI 只按搜索词建；客户端发现页建的带完整作品身份） |
| `GET|PUT resource-indexers` | 资源索引器：内置源启停（`builtin: {nyaa: true, apibay: false, …}`）+ Torznab indexer 清单（`torznab: [{id?, name, endpoint, apiKey?, clearApiKey?, enabled, priority, allowInsecureHttp, categories}]`，整表替换）。API key 不回显（只报 `apiKeySet`），留空沿用同 id 旧值；endpoint 带 `?apikey=` 自动拆出。任一条非法整个请求 400、不落半截。保存后下载管线与订阅服务按新 registry 立即重启（torrent 后端不动），响应的 `providers` 即新的订阅能力位 |
| `GET models` / `POST models/pull {model}` | ASR 各语言 + OCR 模型状态 / 后台拉取 |
| `GET|PUT settings` | 配置读写（下节「远程访问三项」） |
| `GET profiles` / `POST profiles/<id>/share` / `DELETE profiles/<id>` | 寄存的配置文件 + 开关状态 / 指定对端拉取时交出哪一份 / 删除（下节） |
| `GET p2p` | P2P 隧道状态（同 `settings.p2pStatus`，WebUI 轮询用） |
| `GET anki` / `POST anki/login|logout|sync|refresh|landing|run|retry` / `PUT anki/settings` | Anki 落地（下节） |
| `GET|PUT upload?library=<id>&path=<相对路径>` | 分块上传（下节） |

### 远程访问三项

`PUT settings` 的 body 里可带（缺省 = 不改；与其它设置项可同一个请求）：

```json
{"publicUrls": ["https://nas.example.com:38765"], "p2p": true, "p2pRelays": ["https://relay.example.com"]}
```

- `publicUrls` / `p2pRelays` 必须是字符串数组；每条去首尾空白，空行与重复项丢弃；必须 `http://` 或 `https://` 且带主机名，任一条不合法整个请求 400、什么都不写。空数组 = 清空。
- `p2p` 必须是布尔；没有原生库时从关到开返回 409 `{"error": …, "reason": "p2p_unavailable"}`（原本就开着时仍能保存别的项、也能关掉）。
- 返回同 `GET settings`，其中 `p2pStatus`（也是 `GET p2p` 的返回）：

```json
{"available": true, "enabled": true, "active": true, "nodeId": "…", "address": "p2p://…?tls=1&addr=…",
 "relayUrl": null, "directAddrs": ["192.168.1.30:50506"], "reason": null, "lastError": null}
```

`reason` 在未生效时说明原因：`unavailable`（没原生库）/ `disabled` / `host_stopped` / `loopback_bind`（`bind` 只监听本机）/ `start_failed`（看 `lastError` 与日志）。

### AI 下视频（`/api/assistant`）

手机「设置 → 下载 → 下载执行设备」选了这台服务端后，首页「AI 下视频」的整场对话都在服务端跑：
一句话交给**服务端自己配的** AI（`ai:` 段）解析，搜作品走服务端的资料源（同刮削：TMDB 需要 `tmdb_api_key`），
搜资源走服务端的索引器（内置 + Torznab），选定后直接进服务端下载管线（`<data>/documents/downloads`）或建订阅。
手机只收与语言无关的快照、按自己的语言渲染，并按手机的界面语言写 AI 提示词。

- 没有 `ai:` 段或没配全（缺 key / 模型）时，能力位报 `no_provider`，手机据此提示去服务端配置；**不发任何 AI 请求**。
- 下载后端没起来（没内置引擎也没 qBittorrent）时报 `not_ready`。
- WebUI「设置」页的 AI 几项改完**保存即生效**，不用重启；API key 与 qBittorrent 密码同口径：不回显、留空不改。
  admin API：`GET/PUT settings` 的 `ai` 对象（`preset` 置空即关；`apiKey` 只回 `apiKeySet`）。
- 服务端那一家 AI 只指派给「AI 下载」：刮削的 AI 身份识别、补字幕重排等其它 AI 功能在服务端不装配。
- 选了「配字幕」时服务端当前不会装字幕（服务端管线没接字幕源）；每系列字幕语言选择会记进偏好表备用。

### 视频刮削

`video` 库根与 app 的本地视频来源同构：每个根登记一行来源，扫描时分集按作品归成合集、吃进
NFO sidecar，随后自动补刮一轮（`scan_scrape`，默认开）。补刮与 app「视频 → 媒体库 → 自动补刮」
是同一个组件：只刮**从未认领过规范身份**的作品，按作品落盘记账（`<data>/support/video_scrape_sweep_ledger.json`），
查无 / 歧义的作品 7 天内不再自动重试，所以重复扫描不会把整库重刮一遍。

- 资料源与 app 相同（默认主源 AniDB，TMDB 补充 / 兜底）。**TMDB 需要自己配 `tmdb_api_key`**
  （服务端没有 app 的内置 key）；AniDB 读偏好表里的账号 / 客户端，缺了就判不可用，不冒用别人的客户端标识。
- 查无 / 歧义的作品留在待确认队列：在客户端经互联「手动指定身份 / 重新刮削」（以前服务端没接这条，恒返回空）。
- 下载管线导入后的刮削、客户端远程重刮与扫描补刮共用同一个协调器与同一把互斥门。
- WebUI 状态页「刮削」一行显示进度与上次结果；`GET status` 的 `scrape` 字段同源。

### 扫描对账（`scan_prune`）

文件被删掉的视频条目会在扫描后回收（行 + 刮削资料 + 封面；不删任何用户文件、不写跨设备删除墓碑）。
护栏：库根不存在、库根下一个视频都没有（空挂载点）、失效占比超过一半且多于 10 条时拒绝；失效文件所在
目录只剩空壳或读不出来（子挂载点掉线）时这些行保留。拦下的原因在状态页可见。库根列表的「移除并清理」
是显式操作，越过这些推测性护栏；清理没做成（刮削资料清理在跑等）时返回 409、库根保留。

书 / 漫画根同样对账（同一套护栏，`library_prune_guard.dart`）：源 EPUB / `.mokuro` 卷 / 页图卷目录
被删掉后回收那本书（行 + 导入时拷进 `fushi_books/` 的正文副本；不删源文件、不写备份 / 跨设备墓碑，源文件
放回来下次扫描照常再导入）。因为这类导入把正文拷进数据目录、行里记不住源文件，服务端扫描时额外在
`preferences` 表 `media_source_scan_index_<来源 id>` 里记「源相对路径 → 书 uid」，并给书行写上
`sourceId`（每个书 / 漫画根登记一行 `media_sources`，与 app 来源库同构）；已认领的源重扫时不再重复
解压导入。判据只认**本服务端扫描认领过**的书：

- 旧版服务端扫描进来的存量书（没记来源）在下次扫描撞上同名时回填：EPUB 要求标题身份相同且行里记的
  源文件名一致，漫画卷按标题 + 格式认；属于别的库根的书绝不抢。
- 认领不上的（同名书是客户端上传 / 手动导入的，或存量书的源文件在升级前就已删掉）不进索引，永远不会被
  对账删掉——宁可留着，也不按猜测删用户的进度。
- 用户在客户端删掉的书，源文件还在时下次扫描照常重新导入（与以前一样）。
### 配置文件寄存（`profile_transfer`）

互联「配置文件」端点 `/api/interconnect/profile` 与 app 当 host 时同一条（TLS + 已配对 token +
host 开关三道门；开关关着回 403，能力位 `liveLibrary.profileTransfer` 仍报 true 好让客户端分清
「关着」与「不支持」）。服务端的语义是**寄存中转**，不是配置的消费者：

- `PUT`：对端推来的配置方案按 app 同一份解析 / 校验 / 准入判据（引擎 `profile/profile_document.dart`）
  校验后寄存为 `<data>/support/interconnect_profiles/<id>.fushiprofile.json`（可直接在 app「配置管理」
  导入）；重名加 ` (2)` 后缀；坏载荷 400、零落盘。
- `GET`：交出 WebUI 指定「分发中」的那一份，没指定就是最近收到的；一份都没有回 409。
- **不进 `profiles` 表、不应用到服务端**：服务端没有阅读器 / 制卡 / 快捷键可用这些设置；而且
  `profiles` 表非空会让统计分区键从 0 漂到寄存的 Profile、影响互联统计。
- 不从服务端自己的偏好生成配置，所以这条通道带不出服务端任何凭据；寄存物的凭据已由发送端剔除。
- 默认关：没开关的入站写就是隐形写入通道（与 app「允许已配对设备读写本机配置」同一默认）。
  WebUI「配对」页的「配置文件寄存」卡片可一键开关、指定分发、删除。

### 上传协议

`PUT /api/admin/upload?library=<id>&path=Season1/ep01.mkv`，body 是一段字节，头
`Content-Range: bytes <start>-<end>/<total>`。服务端追加到 `<目标>.part`，`start` 必须等于
已收字节数（否则 409），收齐 `total` 后原子改名。`GET` 同 URL 返回 `{"received": n}` 供断点续传。
路径不得逃出库根（400）；累计超 `upload_quota_bytes` 拒收（413）。传完记得扫描库。

## Anki 落地

没装 Anki 的手机也能把卡送进 Anki：手机把 Fushi 的同步后端设为本服务端（互联），制卡时
Anki 不可达 / 开了「批量制卡」的卡进待发队列，同步时经互联写进本机
`<data>/interconnect/sync-data/fushi-data/__pending_mines__/`。本服务端当「落地设备」：
收下这些卡，用 WebUI 里配的牌组 / 笔记类型 / 字段映射渲染，写进本地 Anki 牌组集合，
再同步到 **自建 Anki 同步服务器** 或 **AnkiWeb**；落完写回执，手机下次同步出队。

- 需要随包的 `bin/fushi-anki-sync`（链接 Anki 官方 rslib 26.09.3，AGPL-3.0-or-later，
  源码说明见旁边的 `fushi-anki-sync.SOURCE.txt`）。没带时 WebUI 的 Anki 页如实显示不可用。
- WebUI → Anki：登录同步服务器（密码只用来换取凭据，不保存；AnkiWeb 登录前有条款风险确认）
  → 选牌组 / 笔记类型、填字段映射 → 打开「本机负责落地其它设备的卡片」。
- 数据在 `<data>/support/anki_sync/`（本地牌组集合 + 未同步日志 + 账号凭据）与
  `<data>/support/pending_mine_queue/`。同步成功才出日志；服务器要求整库**上传**时 Fushi
  不做，停在「被拦」，等你在官方 Anki 里同步一次。
- 同一时刻只有一台设备负责落地（最后打开开关的那台）。关掉时立刻撤认领。
- 协议、渲染、同步与 app 共用 fushi_engine 里的同一份代码（`anki_sync/`），设计见
  `docs/specs/2026-09-28-anki-pending-mining-and-sync.md`。

## 词典与远程查词

带上 `libfushidicts_ffi`（与 app 同一个 C++ 引擎，源码 `native/fushidicts/`）时，服务端提供互联查词：
`/api/lookup/dictionary`（含 `popupOnly`）、词典图片 `/api/media/dictionary`，以及查词历史（`record: true` 落服务端
DB 的 `dictionary_history` / `search_history_items`）。`/api/capabilities` 的 `lookup.dictionary` / `lookup.history`
如实反映引擎是否加载成功；加载失败 serve 照常起，查词路由不注册（客户端按不可用处理）。

- 原生库定位：`FUSHI_DICTS_LIB` 环境变量 → `bin/../lib/libfushidicts_ffi.so`（Windows `.dll`、macOS `.dylib`）。
  Linux 自编：`CC=gcc-14 CXX=g++-14 bash native/fushidicts/build_linux_so.sh`，产物
  `native/fushidicts/prebuilt/linux-x64/libfushidicts_ffi.so`（静态链 libstdc++，只动态依赖 glibc；需要支持
  `std::ranges::to` 的编译器，即 GCC 14+，GCC 13 编不过）。CI 的 `build-multiplatform.yml` linux-server 产物已随包
  这份 .so 与变形表；正式发布包（`release-server.yml`，ubuntu-22.04）**尚未**随包，需自行放进 `lib/`。
- 去屈折变形表：`FUSHI_TRANSFORMS_DIR` → `bin/../share/fushi/transforms/` → `bin/transforms/`（目录里要有
  `manifest.json`，内容即 `fushi/assets/transforms/`）。缺表时仍能查原形，但「食べた」查不到「食べる」。
- 词典来源：客户端「词典 · 传输」推送（即时生效），或离线命令：

```
fushi_server dict ls [--json]
fushi_server dict add <yomitan.zip> [--json]   # 同名视为更新，保留排序与隐藏设置
fushi_server dict rm <词典名> [--json]
```

  离线改动在 serve 重启后进引擎。退出码：用法错 64、词典包 / 配置不存在 66、原生库不可用 69、导入失败 1。

制卡转发（`/api/mine`、`/api/mine/forward`、`/api/duplicate`）在服务端带 `fushi-anki-sync` helper 时接线，
落到上面「Anki 落地」的同一个牌组集合；`/api/capabilities` 报 `mining`。

## GPU（CUDA）

随包的是 CPU 版 onnxruntime。要 NVIDIA 加速：

1. 从 [onnxruntime releases](https://github.com/microsoft/onnxruntime/releases) 下 `onnxruntime-linux-x64-gpu-1.22.0.tgz`（版本必须 ≥ 1.22，asr_onnx_ffi 要 API 22），解压到例如 `/opt/ort-gpu`。
2. 装匹配的 CUDA 12.x + cuDNN 9，确保 `libcudart`、`libcudnn` 在 `LD_LIBRARY_PATH`（GPU 包里的 `libonnxruntime_providers_cuda.so` 要能被 dlopen）。
3. 配置 `onnxruntime_library: "/opt/ort-gpu/lib/libonnxruntime.so"`，重启。`fushi_server models status` 的 provider 列会显示 `cuda`；探测失败自动退回 CPU（日志里有原因）。

## 服务端**不**做什么

- 不做游戏串流：`/api/game-stream/*` 恒回 `501 {"error":"unsupported","feature":"gameStream"}`，`/api/capabilities` 报 `gameStream: false`。
- 不做浸入式制卡（`mineImmersion` 回错误）与「在 Anki 里打开」/ 笔记类型编辑 / 媒体去重；查词结果不带词条发音（`lookupAudio` 恒空）。
- 不做查词发音：本地音频库（`/api/library/localaudio`）同词典包一样只做存储中转——客户端推上来的库落 `<data_dir>/support/local_audio_<n>.db`、登记进 `preferences` 表的 `local_audio_dbs`（与 app 同键同形），其它客户端可列出 / 拉取 / 删除；服务端自己不播发音。
- 不做发现页 UI：host 的订阅由客户端发现页（带作品身份）或 WebUI（只按搜索词）创建；host 自己搜 Nyaa / apibay / Knaben / Torznab（Torznab indexer 与停用清单读同一张 `preferences` 表的 `video_resource_torznab_config` / `video_resource_disabled_sources`，与 app 同一编码；在 WebUI「订阅」页的「资源索引器」卡片编辑，保存即生效；不能经互联「配置文件」设——Torznab 配置含 API key，出境时按凭据剔除，服务端寄存的配置文件也不应用到自己身上）。
- 漫画根只认 `.mokuro` 卷与纯页图目录：cbz / cbr / cb7 / pdf 暂不扫描（压缩包导入器还在 app 侧、rar 需外部 7-Zip），这类文件仍走客户端导入。
- 书 / 漫画根的对账只认本服务端扫描认领过的书：客户端上传 / 手动导入的同名书、以及升级前源文件就已删掉的存量书，不会因源文件消失被回收（见「扫描对账」）。

## 开发

```bash
cd packages/fushi_server
dart analyze          # CI 用 dart analyze，info 也致命
dart test             # 配置往返 / 上传分块 / 随包库定位
```

引擎纯度守卫：`fushi/test/build/fushi_engine_purity_guard_test.dart`（`fushi_engine` 不得 import
`package:flutter` / `dart:ui` / 插件 / `package:fushi`）。`dart build cli` 出 bundle 是最终门。
