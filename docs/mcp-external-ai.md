# 让外部 AI 调用 Fushi（MCP 接入说明）

Fushi 桌面版（Windows / macOS / Linux）可以把自己的**操作目录**暴露成一个
[MCP](https://modelcontextprotocol.io/) server，让 Claude Desktop、Claude Code 这类
MCP 客户端直接调用：查库、改设置、下字幕、管下载……app 内「AI 助手」能做的，外部 AI
基本都能做。

- 工具清单由操作目录的描述**自动生成**（每条操作一个工具），不另写一份；目录里新增的操作
  自动出现在 MCP 里。
- 默认**关闭**。要在设置里亲手打开，并生成配对令牌。
- 只监听本机回环地址 `127.0.0.1`，网页里的请求一律拒绝。

## 1. 在 Fushi 里打开

1. 打开 **设置 › 模型 › LLM › AI 助手**。
2. 打开 **外部 AI 访问（MCP）**。
3. 点 **配对令牌**，生成一个令牌。弹窗里可以「复制客户端配置」（Claude Desktop 格式，
   已填好 `fushi_cli` 路径和令牌）或只「复制令牌」。
   - 令牌**只显示这一次**，Fushi 只保存它的 SHA-256 摘要。丢了就重新生成。
   - 重新生成会让旧令牌立刻失效；关掉开关，所有外部客户端的下一次请求都会被拒。

开关和令牌都是设备本地的：不进备份、不随同步或 Profile 漂到别的设备。AI 助手自己改不了
这个开关，也签发不了令牌。

## 2. 在 MCP 客户端里配置

接入走 `fushi_cli mcp`：它是一个 stdio 形式的 MCP server，把每条消息转给正在运行的
Fushi（找端口靠控制通道的发现文件，app 重启后自动接上）。Fushi 没在运行时，它会像其它
`fushi_cli` 命令一样先把 app 拉起来（加全局选项 `--no-launch` 可关掉）。

`fushi_cli` 的位置：

| 平台 | 路径 |
|---|---|
| Windows 安装版 | `fushi.exe` 同目录下的 `fushi_cli.exe`（默认 `%LOCALAPPDATA%\Fushi\fushi_cli.exe`） |
| macOS / Linux | 安装包目前不带，需要自己编：`dart compile exe packages/fushi_cli/bin/fushi_cli.dart -o fushi_cli` |

令牌通过环境变量 `FUSHI_MCP_TOKEN` 传入（也可以 `fushi_cli mcp --token <令牌>`，但命令行
参数会出现在进程列表里，不推荐）。

### Claude Desktop

编辑 `claude_desktop_config.json`（Windows：`%APPDATA%\Claude\claude_desktop_config.json`；
macOS：`~/Library/Application Support/Claude/claude_desktop_config.json`），加入：

```json
{
  "mcpServers": {
    "fushi": {
      "command": "C:\\Users\\<你>\\AppData\\Local\\Fushi\\fushi_cli.exe",
      "args": ["mcp"],
      "env": { "FUSHI_MCP_TOKEN": "<配对令牌>" }
    }
  }
}
```

Fushi 设置页「复制客户端配置」复制出来的就是这一段。保存后重启 Claude Desktop。

### Claude Code

```bash
claude mcp add fushi -e FUSHI_MCP_TOKEN=<配对令牌> -- "C:\Users\<你>\AppData\Local\Fushi\fushi_cli.exe" mcp
```

加 `--scope user` 可在所有项目里使用。`claude mcp list` 能看到连接状态。

### 其它 stdio 客户端（Cursor、Cline、Continue……）

都是同一组字段：命令 = `fushi_cli` 的完整路径，参数 = `mcp`，环境变量
`FUSHI_MCP_TOKEN` = 配对令牌。

### 直接走 HTTP（进阶）

`fushi_cli mcp` 背后是 Fushi 本机控制通道上的 `POST http://127.0.0.1:<端口>/mcp`
（MCP Streamable HTTP，只用 JSON 应答，不开 SSE 流），请求头
`Authorization: Bearer <配对令牌>`。端口**每次启动随机**，写在控制通道发现文件
`endpoint.json` 里（Windows `%LOCALAPPDATA%\Fushi\ctl`、macOS
`~/Library/Application Support/Fushi/ctl`、Linux `${XDG_STATE_HOME:-~/.local/state}/fushi/ctl`）。
所以只适合自己写脚本时用；配置客户端请用上面的 stdio 方式。发现文件里的控制通道 token
**不能**用来访问 `/mcp`，`/mcp` 也只认配对令牌。

## 3. 外部 AI 能做什么、不能做什么

工具名是操作 id 把 `.` 换成 `__`（例如 `settings.set` → `settings__set`），说明就是目录里
给模型看的英文说明，末尾写明执行方式。另有一个 `undo_action` 工具。

| 风险级（沿用操作描述） | 外部调用时 |
|---|---|
| 只读 | 直接执行 |
| 可撤销的写 | 直接执行；结果里带 `actionId`，记入「AI 操作记录」 |
| 装扩展、添加扩展仓库等（`confirm`） | **Fushi 窗口里弹确认框**，你点「执行」才跑；之后仍可撤销 |
| 不可逆（删磁盘文件、向第三方发数据……） | **Fushi 窗口里弹确认框**，你点「执行」才跑 |

- 确认框只能在 Fushi 里点。外部 AI 填不出「已确认」：确认类参数（`confirm`、
  `trustSigner` 等）不在工具 schema 里，带上就直接报错；风险级也由目录决定，调用方改不了。
- 确认框会把 Fushi 窗口带到前台，显示请求方自报的客户端名、操作、参数。2 秒内不能点
  「执行」（防误按回车）；2 分钟没人回答按拒绝处理。多个确认排队，一个一个弹。
- 和 app 内 AI 助手一样：凭据类设置（API key、密码）读不到也写不了；带凭据服务的地址改
  不了；授权类开关（例如本开关、「允许已配对设备使用 AI 助手」）改不了；工具结果里像凭据
  的字段会被抹掉。
- 只在 app 界面里有意义的操作（打开某个设置页并高亮）和会返回一次性凭据的操作（配对票据
  等）不对外。

## 4. 看到并撤销外部 AI 做过的事

外部 AI 的每次写操作都进 **设置 › 模型 › LLM › AI 助手 › AI 操作记录**，按 MCP 会话分组
（会话 id 以 `mcp:` 开头），和 app 内 AI 助手的记录在一起：

- 每条可撤销的操作都有「撤销」，也可以整组撤销。
- 外部 AI 自己可以用 `undo_action`（参数 `actionId`）撤销它这条连接做过的事；它撤不了
  app 内 AI 助手的记录。
- 撤销前如果你又手动改过同一处，撤销会报「已被后续修改覆盖」并保留你的修改。
- 命令行：`fushi_cli ai log` / `fushi_cli ai undo <id>`。

## 5. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `External AI access is off` | 设置里没打开「外部 AI 访问（MCP）」 |
| `No pairing token yet` | 打开了，但还没生成配对令牌 |
| `Missing or wrong pairing token` | 令牌不对，或已重新生成过；把新令牌填进客户端配置并重启客户端 |
| `Fushi is not running` | 用了 `--no-launch`，或找不到 / 拉不起 Fushi（`--app <路径>` 或环境变量 `FUSHI_APP` 指定） |
| `Fushi is still starting up` | app 还在初始化，稍后再试 |
| 工具调用一直不返回 | Fushi 里在等你点确认框（窗口可能在别的桌面 / 被最小化了） |
| `user_declined` / `confirmation_expired` | 你拒绝了，或 2 分钟内没回答 |
| 手机上没有这个开关 | MCP 挂在桌面控制通道上，只有桌面版有 |

实现与取舍见 `docs/specs/2026-10-26-ai-operations-agent-design.md` §12.5；代码在
`packages/fushi_cli/lib/src/mcp/`（协议、`/mcp` 传输、stdio 桥）与
`fushi/lib/src/ai/mcp/`（目录适配、确认、鉴权）。
