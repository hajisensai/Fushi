# fushi_cli

Fushi 桌面客户端（Windows / macOS / Linux）的命令行。它不自己读写数据库，而是经
**本机控制通道**驱动正在运行的 Fushi app；app 没开时自动拉起并等它初始化完成。

```
fushi_cli status            # app 是否在运行（不拉起；未运行退出码 69）
fushi_cli start             # 确保 app 在运行并就绪
fushi_cli open <路径|URL>   # 打开视频文件 / fushi:// 深链 / 卡片来源 URL
fushi_cli lookup <词>       # 弹出查词
fushi_cli quit              # 落库后退出 app（与关窗口同一条路径）
```

全局选项：`--json`（机器可读输出）、`--app <路径>`、`--timeout <秒>`（默认 90）、
`--no-launch`。

退出码与 `fushi_server ctl` 同一套 sysexits 约定：0 成功 / 1 app 拒绝或请求失败 /
64 用法错误 / 69 app 未运行、找不到或起不来 / 75 等待就绪超时（稍后重试）/
77 鉴权失败 / 78 控制通道目录解析不出。

## 控制通道

- app 启动时（`fushi/lib/main.dart` 的 `_startCtlServer`）在 `127.0.0.1` 随机端口开
  一个 HTTP 服务，每次启动新生成 token，把 `{port, token, pid}` 原子写到发现文件
  `endpoint.json`。请求一律 `Authorization: Bearer <token>`；带 `Origin` 头（网页
  fetch）的请求直接 403。
- 发现文件目录（两侧同一套解析，见 `lib/src/ctl_paths.dart`）：`FUSHI_CTL_DIR` >
  测试根 `<FUSHI_TEST_ROOT>/ctl` > Windows `%LOCALAPPDATA%\Fushi\ctl` / macOS
  `~/Library/Application Support/Fushi/ctl` / Linux `${XDG_STATE_HOME:-~/.local/state}/fushi/ctl`。
  POSIX 上目录 700、文件 600。
- 路由沿用 `fushi_server` 管理 API 的 `/api/admin/*` 形态：`GET /api/admin/status`；
  桌面独有动作在 `POST /api/admin/app/{open,lookup,quit}`。
- `open` 只认 argv / 单实例转交认的那组候选，并交给同一个出口落地，不另开打开路径。
- `FUSHI_CTL=off` 时 app 不开控制通道。

## 找 app

`--app` > `FUSHI_APP` > CLI 同级目录的 `fushi(.exe)` > 默认安装位置（Windows
`%LOCALAPPDATA%\Fushi\fushi.exe`，macOS `/Applications` 与 `~/Applications` 下的
`fushi.app`）。Windows 安装包把 `fushi_cli.exe` 放在 `fushi.exe` 旁边。

## 构建

```
dart compile exe packages/fushi_cli/bin/fushi_cli.dart -o fushi_cli.exe
```

纯 Dart、无原生资产，`dart compile exe` 即可（与 fushi_server 不同，不需要 `dart build cli`）。
