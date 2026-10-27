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
| `library` | 书架 / 媒体库条目 ls / get / rm、导入、打开到指定位置（`--chapter` / `--page` / `--at`）、改名、换封面、标记完成、重置进度、来源库增删改与扫描、最近打开 |
| `collection` / `tag` / `bookmark` / `favorite` | 合集（含播放列表）建删改与成员（成员数只计库页画得出来的成员）、手动定序 `collection order`、一键排序 `collection sort --by title\|imported\|ai`（`ai` = SP / OVA / 汉字卷号等规则判不出的成员交 AI 定位，`--dry-run` 只打印建议序）；标签、书签、收藏句管理与导出 |
| `reader` | 遥控当前打开的 EPUB / PDF / 漫画阅读器：状态、翻页、按章 / 页 / 百分比跳转 |
| `audiobook` / `ocr` | 有声书附着 / 替换音频与字幕、重新匹配、转录（含挂到已有书 `--into`）及任务；漫画整卷 OCR（`--force` / `--engine` / `--consent-upload`） |
| `dict` / `anki` | 词典管理、推荐词典与推荐包下载导入、改名与语言覆盖；Anki 制卡、待发队列（pending / send / retry / discard）、内置同步客户端登录与同步 |
| `config` / `module` / `profile` / `stats` / `keys` | 设置项读写与动作执行（`config get/set/run/reset`，列表型 `config items`；独立设置页的条目也在其中）、模块开关与排序、Profile 及媒体 / 语言绑定、学习统计、快捷键改绑 / 解绑 / 重置 |
| `ai` / `models` / `voice` / `audiosrc` | LLM 提供商与功能指派、OCR / ASR / GPT-SoVITS 模型下载与删除及本机服务起停、TTS 声音与语速、查词音频来源 |
| `task` / `update` | 通用后台任务查询 / 等待 / 取消；检查更新、下载、安装 |
| `backup` / `sync` / `dl` / `sub` / `mediaserver` / `peer` / `storage` | 备份（含按书 / 视频）与恢复、云同步与差异逐条应用、下载中心（直接入队、目标库、字幕策略、执行设备、优先级、互联 host 上的任务）、视频下载订阅（列表 / 逐集历史 / 立即检查 / 启停 / 编辑规则 / 删除；新建走 `aidl`）、Jellyfin / Emby / Plex（含 Plex PIN 授权）、互联配对链接与吊销、存储占用与数据目录迁移 |
| `ext` / `source` / `discover` / `play` / `nav` / `aidl` | 扩展启停、源启停 / 置顶 / 偏好 / 筛选浏览、漫画章节与视频剧集下载任务、发现与一键获取、播放遥控、页面跳转、AI 下载会话（消歧 / 确认 / 取消） |
| `video` | 作品与刮削（含 `video confirm` 回答待确认候选）、播放器音量 / 音轨 / 主副字幕、字幕导入 / OCR / 转录 / 对轴、在线字幕立即补 / 手动搜 / 点名下载（`video sub-fetch` / `sub-search` / `sub-get`）、字幕位置、着色器、制卡与暂存队列、片段导出、长任务、生成日语字幕（`video subtitle-gen` / `video subtitle-glossary`） |
| `game`（仅 Windows） | 游戏库管理与刮削、启动 / 附着 / 停止、文本线程与当前台词、音轨与补录、分阶段能力状态、制卡、内嵌查词模式与截图校准 |

app 侧路由在 `fushi/lib/src/ops/ctl_*.dart`，CLI 侧命令在 `lib/src/commands/*_commands.dart`；
每条路由都调用 app 里 UI 按钮背后的同一个方法，不另写业务逻辑。破坏性操作（删除、恢复备份、覆盖）必须加
`--yes`；需要用户同意的上传 / LLM 处理用显式参数（`--consent-upload` / `--consent-llm`）表态，不在 app 里弹框；
凭据只经 stdin 或环境变量传入。长任务立即返回任务 id，用对应的 `job` / `task get --wait` 查进度、`cancel` 取消，
进入写盘阶段后拒绝取消。

**新增 UI 操作必须同时接 ctl 路由与 CLI 命令**：`fushi/test/ops/ctl_cli_route_coverage_guard_test.dart`
双向钉死「每条路由都有 CLI 命令、每条 CLI 请求都落到路由」；设置页动作由
`fushi/test/settings/settings_cli_action_coverage_test.dart` 要求声明 CLI 入口。

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
