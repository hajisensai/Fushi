# Fushi 音乐插件开发包（Music plugin SDK）

给 Fushi 音乐模块写「插件音源」用的开发包：一个零依赖的 Node 命令行工具（只需要 Node.js 18+）、
TypeScript 类型、新插件模板，以及一个可以直接跑的示例插件。
**完整契约只有一份：[GUIDE.md](GUIDE.md)**（英文，按「直接交给 AI 编程助手」的标准写，
人和 AI 读的是同一份）。

English: this folder is the plugin SDK for Fushi's music module. Start with [GUIDE.md](GUIDE.md).

## 拿到开发包

只要这一个目录，不用克隆整个仓库：

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/hajisensai/fushi.git
cd fushi && git sparse-checkout set tools/music-plugin-sdk
```

## 五条命令走完全程

```sh
node fushi-plugin.mjs init my-plugin --id dev.yourname.mysource --name "My Source"
node fushi-plugin.mjs run my-plugin search '{"query":"lemon","type":"song","page":0,"pageSize":10}' --trace
node fushi-plugin.mjs smoke my-plugin --query lemon --strict
node fushi-plugin.mjs keygen --out my-plugin-key.pem
node fushi-plugin.mjs pack my-plugin --key my-plugin-key.pem
```

在 Fushi 里安装：设置 › 音乐 › 插件音源 › 从文件安装。iOS 不支持插件。

## 用 AI 写插件

`init` 生成的插件目录里自带 `GUIDE.md`、`fushi-plugin.d.ts`，以及给 agent 的 `AGENTS.md` / `CLAUDE.md`
（写好了命令和规矩）。在这个目录里打开 Claude Code、Codex、Cursor 之类的工具，告诉它「给 <某站> 实现
search / album / stream / lyrics」就行。验收标准是 `smoke --strict` 退出码为 0。GUIDE.md §9 有一段可以
直接复制的提示词。

`run` / `smoke` 在一个和 app 行为一致的沙箱里执行插件：同一份前奏脚本、同样的全局对象、网络授权、
上限和 CPU 预算；返回值按 app 的解析逻辑逐项检查。`ERROR` 表示 app 里会失败，`WARN` 表示 app 会静默丢掉
或忽略某些数据。

**本地运行器不是安全隔离**：它基于 Node 的 `vm`，恶意插件可以逃逸到 Node 进程、读写你的文件。只用它跑
自己写的或可信的插件；真正的隔离边界是 app 内的 QuickJS 沙箱，本地运行器只复刻它的规则。

## 目录

| 路径 | 内容 |
|---|---|
| `GUIDE.md` | 完整契约：工作流、易错规则、manifest、运行时 API、能力与实体、登录、打包签名、排障、AI 提示词 |
| `fushi-plugin.mjs` | 命令行：`init` / `check` / `run` / `smoke` / `login` / `reset` / `keygen` / `pack` / `inspect` |
| `fushi-plugin.d.ts` | 全部类型（JS 里用 JSDoc 引用即可获得补全和类型检查） |
| `templates/starter/` | `init` 用的模板 |
| `examples/archive-netlabels/` | 示例插件：Internet Archive 上 CC 授权的 netlabel 发行 + LRCLIB 歌词 |
| `lib/` | 工具内部实现；`lib/prelude.js` 是宿主前奏 `native/fushi_music/src/plugin/prelude.js` 的逐字节副本 |

## 维护（Fushi 仓库内）

宿主契约的真相源仍是 `docs/specs/2026-10-28-music-plugins.md` 与 `native/fushi_music/src/plugin/`、
`packages/fushi_music/lib/src/plugin/`。改了宿主规则（能力、权限、上限、实体字段、前奏）要同步改
`lib/rules.mjs` / `lib/validate.mjs` / `fushi-plugin.d.ts` / `GUIDE.md`。前奏副本、能力 / 权限清单与
`LIMITS` 里有宿主常量对应的上限（包大小、请求头 / 请求体、存储、在途 / 单步宿主调用、凭据条数）由守卫
`fushi/test/build/music_plugin_sdk_sync_guard_test.dart` 钉住，其余靠审查。

`lib/prelude.js` 与 `lib/runner.mjs` 在 `.sonarcloud.properties` 里排除出 Sonar 分析：前者是宿主前奏的逐字节
副本（重复与问题都记在宿主那份上），后者按设计用 `vm.runInContext` 执行插件代码（S1523 是它的职责本身）。
