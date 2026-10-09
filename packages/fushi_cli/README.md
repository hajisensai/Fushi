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

按域的命令（`fushi_cli <域> --help` 看子命令，`fushi_cli <域> <命令> --help` 看选项）：

| 域 | 覆盖 |
|---|---|
| `library` | 书架 / 媒体库条目 ls / get / rm、导入（EPUB / PDF / 文本 / 漫画 / 有声书 / 视频 / 游戏）、在 app 里打开、最近打开、来源库扫描 |
| `dict` / `anki` | 词典 ls / 启用停用 / 排序 / 删除 / 导入 / 在线更新、结构化查词结果；Anki 状态、牌组、笔记类型、制卡、查重、同步 |
| `config` / `module` / `profile` / `stats` / `keys` | 设置项读写（与设置页同一入口，机密打码）、模块开关、Profile 管理与导入导出、学习统计、快捷键清单 |
| `backup` / `sync` / `dl` / `mediaserver` / `peer` / `storage` | 备份创建与恢复（`--merge` / `--replace` 预设）、云同步（可指定通道）、下载中心（含 http 直链）、Jellyfin / Emby / Plex 浏览与搜索、互联 host 与配对、存储占用 |
| `ext` / `source` / `discover` / `play` / `nav` | 漫画 / 视频 / 小说扩展与仓库、在线源搜索 / 加库 / 下载、发现与一键获取、视频 / 有声书播放遥控（`--target`）、顶层页面跳转 |
| `video` | 视频作品列表、刮削 / 重刮 / 取消、手动识别（AniDB / MAL / TMDB）、视频发现、资源搜索与下载入队 |

app 侧每个域一个路由文件 `fushi/lib/src/platform/desktop/ctl/ctl_<域>_routes.dart`，CLI 侧一个命令文件
`lib/src/commands/<域>_commands.dart`；每条路由都调用 app 里 UI 按钮背后的同一个方法，不另写业务逻辑。
破坏性操作（删除、恢复备份、覆盖）必须加 `--yes`。

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
