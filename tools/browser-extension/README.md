# Fushi 浏览器扩展（Fushi Reader Bridge）

在任意网页上用 Fushi 的词典查词、采集/加载流媒体字幕、批量制卡。扩展本身没有词典和
Anki 能力——一切经本机 Fushi 桌面 App 内置的 yomitan API server（默认
`http://127.0.0.1:19633`，HTTP + Basic auth）完成。**没有构建步骤**：纯 JS 散文件，MV3。

## 文件地图

| 文件 | 世界 | 职责 |
|---|---|---|
| `manifest.json` | — | MV3 清单；content script 注入顺序有语义（先桥后消费者） |
| `background.js` | service worker | 唯一网络出口：查词/制卡/字幕等所有 HTTP 请求 + 连接诊断 + 自更新执行 + 心跳 + Netflix 录制编排 |
| `content.js` | 隔离 | Shift 悬停查词、查词暂停、弹窗渲染/定位、高亮、挖词队列、字幕轨 provider（textTracks 收割 / DOM 采样 / 整集拦截接收端）、Netflix/YouTube 批量制卡驱动 |
| `subtitle-panel.js` | 隔离 | 字幕列表侧栏 + 视频覆盖层 + 外挂字幕加载 + 全轨时轴偏移 + 悬浮字幕自动查词/防剧透模糊 + 快捷键执行端 |
| `video-shortcuts.js` | 隔离 | 视频页快捷键判定（纯函数）+ 绑定；每个动作独立开关，动作交 subtitle-panel 执行 |
| `netflix-bridge.js` | MAIN | Netflix 专用：JSON.parse hook 抓整集字幕 + 官方 player.seek（避开 DRM M7375） |
| `stream-bridge.js` | MAIN | 通用流媒体字幕桥（asb 移植）：TVer / Bilibili.tv / Hulu JP / Prime Video 整集字幕拦截 |
| `THIRD_PARTY_LICENSES.md` | — | 随扩展分发的第三方版权与许可文本（当前含 asbplayer MIT） |
| `subtitle-adapters.js` | 隔离 | 纯函数字幕解析器：WebVTT/SRT、TTML、Bilibili JSON + Netflix 取词/标题 |
| `bridge-shim.js` | 隔离 | 垫掉 app 内 WebView 桥（`flutter_inappwebview.callHandler`）→ chrome 消息，复用 vendor/popup.js |
| `scan.js` | 隔离 | 取词纯函数（词窗扩展/句子抽取） |
| `self-update.js` | SW/options | 自更新决策纯状态机 + 状态文案（node 可测） |
| `connection-diagnostics.js` | SW/options | 连接六态分类 + 中文文案（纯函数） |
| `fushi-defaults.js` | SW/options | 安装助手写入的自动配置（host/port/token/build 指纹） |
| `offscreen.html/js` | offscreen | tabCapture MediaRecorder（Netflix 逐句回放录制） |
| `options.html/css/js` | options | 设置页：连接、字幕偏好、逐动作视频快捷键、版本与更新卡片 |
| `vendor/` | — | `popup.{js,css,html}`+`selection.js` = app 查词弹窗原样拷贝（上游 `hibiki/assets/popup/`）；`dict-media.js` 允许扩展分叉；`content.css` 由生成器产出；`action-popup.*` 扩展独有 |
| `scripts/` | 开发 | `generate-content-css.mjs`（popup.css → 零特异性重根 content.css）、`sync-mirrors.mjs`（镜像同步） |

## 三份镜像与同步（改代码必读）

```
hibiki/assets/popup/  ──(手动 cp，方向固定)──▶  vendor/popup.js 等四件套
tools/browser-extension/（真源，本目录） ──(node scripts/sync-mirrors.mjs)──▶ hibiki/assets/browser_extension/（Flutter asset）
scripts/generate-content-css.mjs ──▶ 两处 vendor/content.css
```

- **任何改动后跑 `node scripts/sync-mirrors.mjs`**（或 `--check` 只校验）。`*.test.js`、
  `scripts/`、`README.md` 不进 bundle；`THIRD_PARTY_LICENSES.md` 必须进入 bundle 与安装目录。
- Dart 守卫（`hibiki/test/build/browser_extension_*` 等 30+ 个）会把「两镜像字节一致」当
  最后防线，漏同步 CI 必红。
- 新增文件放本目录**平级**（或 `vendor/`）——`hibiki/pubspec.yaml` 只声明了这两层 asset 目录。

## 安装（导入浏览器）流水线

1. 本目录随 app 以 Flutter asset 打包（镜像 `hibiki/assets/browser_extension/`）。
2. app 扩展页「准备扩展」→ `browser_extension_installer.dart` 解压到
   `<appSupport>/hibiki-browser-extension/`，并把**当前 server 真值**（host/port/token）与
   **内容指纹 build**（全部文件排除 `fushi-defaults.js` 的 sha256 前 16 hex）写进
   `fushi-defaults.js` → 用户浏览器「加载已解压」后零配置可用。
3. 用户可在 options 页覆盖连接参数（chrome.storage.local 优先于内置默认）。

## 自更新流水线

```
app 升级
  └─ 启动时 refreshBundledBrowserExtensionIfStale()：磁盘副本指纹 ≠ 内置 → 整目录重解压（新 build）
浏览器侧（background.js + self-update.js 纯状态机）
  └─ SW 唤醒 / onStartup / onInstalled / 60s 心跳 / 每次查词响应 → 拿 server 下发的 extensionBuild
       decide(remote, local, reloadedFor, recording)：
         remote == local        → clear（清 stale 提示/角标）
         首见新 build           → chrome.runtime.reload()（从磁盘拉新；先置重注入标记）
         已 reload 过仍不一致    → stale：图标「↑」角标 + action-popup 提示 + options「版本与更新」卡片
         录制中                 → 跳过本轮（reload 会杀 offscreen 录制）
  └─ reload 后：fushiReinjectPending → 向已打开页面补注 content script（无需手动刷新）
可视化：options 页「版本与更新」卡片实时显示 当前 build / 自动更新状态 / 失效指引
        （self-update.js describeUpdateState，扩展自报版本走 /api/extension/status 请求体）
```

## 与 App 的通信（endpoint 速览）

全部 `POST http://<host>:<port>/api/...`，`Authorization: Basic base64('fushi:'+token)`。
查词 `/api/lookup/dictionary` · 单词音频 `/api/lookup/audio` · 制卡 `/api/mine` · 查重
`/api/duplicate` · 状态/心跳 `/api/extension/status` · 弹窗尺寸 `/api/extension/popup-size` ·
YouTube 整集字幕 `/api/youtube/captions` · 外挂字幕解析 `/api/subtitle/parse`。
服务端实现：`hibiki/lib/src/sync/yomitan_api_server.dart`。

## 字幕轨数据流（面板零站点特例）

所有来源写同一个 store：`window.fushiEpisodeCues['${videoKey}|${lang}'] = [{startMs,endMs,text}]`，
新数据到达调 `window.fushiSubtitlePanelOnCues(key)`。来源：
① Netflix 整集拦截（netflix-bridge）② 通用流媒体桥（stream-bridge，见下表）③ YouTube 服务端
整集字幕 ④ 原生 `video.textTracks` 收割 ⑤ DOM 字幕采样 live 轨 ⑥ 用户外挂文件（`外挂:` 前缀轨）。
时轴偏移是**读取侧**的（store 永远存原始 cue），任意轨可偏移，会话内记忆。

## 站点适配状态

| 站点 | 机制 | 验证状态 |
|---|---|---|
| Netflix | JSON.parse hook + 官方 seek（netflix-bridge） | ✅ 已真站点验证（既有） |
| YouTube | 服务端 androidVr 解析（/api/youtube/captions）+ live 采样兜底 | ✅ 已真站点验证（既有） |
| TVer | JSON.parse hook（stream-bridge，asb tver-page 移植） | ⚠️ implemented_unverified |
| Bilibili.tv（国际站） | JSON.parse hook，srt/bbjson | ⚠️ implemented_unverified |
| Hulu（日本） | XHR 响应旁路（ref_id + tracks） | ⚠️ implemented_unverified |
| Prime Video | 捕获 GetVodPlaybackResources 重放 → TTML | ⚠️ implemented_unverified |
| 其它站点 | 通用：textTracks 收割 + DOM live 采样 + 外挂字幕 | ✅ 通用路径既有 |

⚠️ = 提取逻辑逐行对照 asbplayer 已上线适配器移植、纯函数有 node 单测，但本仓库开发环境无对应
账号，未做真站点端到端验证；上线前请在真站点各过一遍（打开视频 → 字幕列表出现整集轨）。

**新增站点适配器步骤**：① `stream-bridge.js` 加纯函数提取器 + `siteForHost` 路由 + 对应
hook 安装；② `manifest.json` 的 stream-bridge matches 加域名；③ 新格式则在
`subtitle-adapters.js` 加解析器并在 `content.js` `fushiOnStreamCues` 分派；④ 加
`stream-bridge.test.js` 样例 JSON 测试；⑤ 跑 sync-mirrors。参考 asbplayer
`extension/src/entrypoints/*-page.ts`（MIT）。

## 快捷键（视频页，options 逐动作独立开关）

| 键 | 动作 |
|---|---|
| ← / → | 上一句 / 下一句字幕（仅当前视频有字幕轨时接管） |
| ↑ | 回当前句句首重播 |
| Shift+S | 开关字幕列表面板（当前视频有 Fushi 字幕轨时） |
| Shift+H | 隐藏 / 显示字幕（站点原生字幕 + 扩展覆盖层；**不**需要 Fushi 字幕轨） |
| Ctrl+Shift+← / → / ↓ | 字幕偏移 −100ms / ＋100ms / 重置 |
| Ctrl+Shift+Z | 复制当前字幕句（配合 Fushi 剪贴板监看即查词） |
| Ctrl+Shift+[ / ] | 播放速度 −0.25x / ＋0.25x（0.25–4x） |

这里使用固定键位 + 纯函数判定；每个动作在扩展设置页各有自己的开关。站点输入框/可编辑区
一律放行；无轨时方向键及 Shift+S 均放行给站点原生行为。

`Shift+H` 的「隐藏」用 `visibility:hidden` 而非 `display:none`：扩展的取词、逐句制卡、caret
兜底命中都要读字幕节点的 textContent / 几何，`display:none` 会把它们摘出布局，隐藏字幕就
等于顺手废掉制卡。状态存 `chrome.storage.local.subtitleHidden`，与 options 页的「隐藏字幕」
开关双向同步（守卫见 `subtitle-hide.test.js`）。

## 制卡快捷键（查词弹窗打开时）

| 键 | 动作 |
|---|---|
| Ctrl+Enter | 制卡 = 点弹窗里的「＋」（Anki 三态 ＋/✓/✓↩︎ 与鼠标点击完全同源） |

不受上面的「视频页快捷键」总开关影响——它属于查词弹窗而不是视频页。按键判定在共享的
popup.js 中；app 内由宿主分发快捷键，浏览器扩展没有绑定注入通道，使用内置默认值
Ctrl+Enter。Windows app 外按焦点分流：可聚焦的剪贴板面板只有在用户点入并获得键盘焦点后，
才使用 Fushi 设置 → 快捷键 → 查词弹窗 → 制卡里的可改键绑定；永不抢焦点的瞬态查词覆盖窗
带 `WS_EX_NOACTIVATE`，收不到键盘事件，因此没有制卡快捷键，也不注册全局热键，避免让当前
游戏失焦。只有真的点到了按钮才吞掉按键，IME 组词期间与输入框内一律放行。

## 测试

```
node --test            # 本目录全部 *.test.js（node 内置 runner，零依赖）
```

Dart 侧守卫（跑法见仓库根 CLAUDE.md）：`hibiki/test/{build,lookup,mining,sync,...}/browser_extension_*`
做镜像字节一致 + 功能链存在性扫描。扩展 JS 单测目前不在 CI，提 PR 前请本地跑过。
