# fushi_server — 无头 Fushi 服务端（Linux / Windows / macOS）

`fushi_server` 是 Fushi 的无 GUI 服务端：一个 CLI 进程，跑与桌面 Fushi **同一份**互联
host（`packages/fushi_engine`），带 WebUI。装在 NAS / 家用服务器 / VPS 上，手机和桌面
Fushi 通过「互联」配对后，把这些活丢给它：

| 能力 | 协议 | 说明 |
|---|---|---|
| 媒体库 host（视频 / 书 / 漫画 / 有声书 / 词典包） | `/api/library/*`（冻结面） | 服务端扫描本机目录入库，客户端浏览、拉流、同步进度 |
| 漫画整卷 OCR | `/api/manga_ocr/*` | 客户端上传卷，服务端跑 ONNX 检测+识别，回传 mokuro |
| 字幕识别（ASR） | `/api/jobs`（kind=`asr`） | 客户端上传音轨或指定 host 视频，服务端转录成 SRT + token 时间轴 |
| 代下载 | `/api/downloads` | 内置 libtorrent 引擎或外接 qBittorrent，落 `<data>/documents/downloads` 后自动入库 |
| WebUI / admin API | `http(s)://<host>:38780/` | 状态、配对 PIN、库根管理、上传、任务、下载、模型、设置、日志 |

设计文档：[`docs/specs/2026-09-08-fushi-server-headless-design.md`](../../docs/specs/2026-09-08-fushi-server-headless-design.md)。

## 安装

CI（`build-multiplatform.yml` 的 linux job）产出 `fushi_server-linux-x64` 工件，布局：

```
bundle/
  bin/fushi_server            # 可执行文件
  lib/libsqlite3.so           # dart build 的 native asset
  lib/libfushi_torrent_ffi.so # 内置 torrent 引擎 bridge（动态链接发行版 libtorrent-rasterbar 2.0）
  lib/libonnxruntime.so*      # onnxruntime 1.22.0 CPU 版（OCR / ASR）
```

解压到任意目录即可（例 `/opt/fushi_server`）。**目标机运行期依赖**（Debian/Ubuntu）：

```bash
sudo apt-get install -y libtorrent-rasterbar2.0 libssl3 ffmpeg
```

- `libtorrent-rasterbar2.0`：内置 torrent 引擎；没有它只是内置引擎不可用（`torrent.engine: auto` 会退到外接 qBittorrent，都没有就报 `supported=false`），其他功能照常。
- `ffmpeg`：视频封面抽帧、ASR 音轨解码、下载后转封装。不在 PATH 时用环境变量 `FUSHI_FFMPEG=/path/to/ffmpeg`。
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
Environment=FUSHI_FFMPEG=/usr/bin/ffmpeg

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
# ffmpeg: "/usr/bin/ffmpeg"   # 只做展示；真正生效走环境变量 FUSHI_FFMPEG
# onnxruntime_library: "/opt/ort-gpu/lib/libonnxruntime.so"   # 换 GPU 版 ORT 时指过去
upload_quota_bytes: 53687091200   # WebUI 上传累计配额（50 GB），防被当网盘
torrent:
  engine: "auto"              # auto | embedded | qbittorrent
  # library: "/opt/fushi_server/lib/libfushi_torrent_ffi.so"   # 缺省找 bundle/lib，再找系统路径
  listen: "0.0.0.0:6881,[::]:6881"
qbittorrent:                  # engine=qbittorrent 或 auto 无内置库时用
  url: "http://127.0.0.1:8080"
  username: "admin"
  password: "..."
libraries:
  - id: "anime"
    path: "/srv/media/anime"
    kind: "video"             # video | book
    enabled: true
```

WebUI「设置」页改的就是这个文件；端口 / TLS / 绑定 / torrent / qBittorrent / ORT 路径改后要重启 `serve`。

## CLI

```
fushi_server init                      生成配置
fushi_server serve [--scan]            起服务（Ctrl-C / SIGTERM 优雅停）
fushi_server scan                      扫描 libraries[] 入库（不起服务）
fushi_server status                    打印库/配对概况
fushi_server pair ls | revoke <peerId> 已配对设备
fushi_server admin reset-token         重生成 admin_token
fushi_server models status | pull <lang|ocr>   模型状态 / 拉取
fushi_server transcribe <media> --lang ja [--cpu]   本地跑一次 ASR（调试）
```

所有子命令接受 `--config <path>`（默认当前目录 `fushi_server.yaml`）和 `--verbose`。

## admin API（WebUI 用的那套）

鉴权：`Authorization: Bearer <admin_token>`，或浏览器 `POST /login`（表单 `token=`）拿 cookie。全部 JSON，前缀 `/api/admin/`：

| 路由 | 说明 |
|---|---|
| `GET status` / `GET logs` | 运行状态、最近 500 行日志 |
| `GET pairing` / `DELETE pairing/peers/<id>` | 待输入 PIN + 已配对列表 / 吊销 |
| `GET|POST libraries` / `DELETE libraries/<id>` / `POST scan` | 库根管理（写回 yaml）/ 触发扫描（单飞） |
| `GET jobs` / `DELETE jobs/<id>` | 互联任务（ASR 等） |
| `GET|POST downloads` / `POST downloads/<id>/cancel|retry` / `DELETE downloads/<id>` | 代下载 |
| `GET models` / `POST models/pull {model}` | ASR 各语言 + OCR 模型状态 / 后台拉取 |
| `GET|PUT settings` | 配置读写 |
| `GET|PUT upload?library=<id>&path=<相对路径>` | 分块上传（下节） |

### 上传协议

`PUT /api/admin/upload?library=<id>&path=Season1/ep01.mkv`，body 是一段字节，头
`Content-Range: bytes <start>-<end>/<total>`。服务端追加到 `<目标>.part`，`start` 必须等于
已收字节数（否则 409），收齐 `total` 后原子改名。`GET` 同 URL 返回 `{"received": n}` 供断点续传。
路径不得逃出库根（400）；累计超 `upload_quota_bytes` 拒收（413）。传完记得扫描库。

## GPU（CUDA）

随包的是 CPU 版 onnxruntime。要 NVIDIA 加速：

1. 从 [onnxruntime releases](https://github.com/microsoft/onnxruntime/releases) 下 `onnxruntime-linux-x64-gpu-1.22.0.tgz`（版本必须 ≥ 1.22，asr_onnx_ffi 要 API 22），解压到例如 `/opt/ort-gpu`。
2. 装匹配的 CUDA 12.x + cuDNN 9，确保 `libcudart`、`libcudnn` 在 `LD_LIBRARY_PATH`（GPU 包里的 `libonnxruntime_providers_cuda.so` 要能被 dlopen）。
3. 配置 `onnxruntime_library: "/opt/ort-gpu/lib/libonnxruntime.so"`，重启。`fushi_server models status` 的 provider 列会显示 `cuda`；探测失败自动退回 CPU（日志里有原因）。

## 服务端**不**做什么

- 不装词典 FFI 引擎（`fushidicts`）：服务端只托管词典包文件供客户端同步，查词仍在客户端本地；Linux 桌面版 Fushi 自带 `libfushidicts_ffi.so`，与服务端无关。
- 不做发现页（Nyaa/Torznab 搜索订阅）：只接客户端投来的磁力/种子。订阅仍在客户端本地跑，可以把下载目标选成 host。
- 不扫描漫画目录（漫画走客户端上传 / OCR 任务）。

## 开发

```bash
cd packages/fushi_server
dart analyze          # CI 用 dart analyze，info 也致命
dart test             # 配置往返 / 上传分块 / 随包库定位
```

引擎纯度守卫：`fushi/test/build/fushi_engine_purity_guard_test.dart`（`fushi_engine` 不得 import
`package:flutter` / `dart:ui` / 插件 / `package:fushi`）。`dart build cli` 出 bundle 是最终门。
