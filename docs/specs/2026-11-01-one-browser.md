# 用户只看到一个浏览器（2026-11-01）

## 起因

用户反馈：「一般用户不会明白播放器网页和普通网页的区别」。在此之前 Windows 上有两套浏览器外壳：

1. **app 内浏览器**（`fushi_web_browser_page.dart` + `web_browser/`）：多标签页、地址栏、书签 / 站点格、扩展、登录导入、阅读模式、学习统计……
2. **视频页的「网页档」**（`video_fushi/web_source.part.dart` 的 `_buildWebPageBar`）：底层合成（WebView2 窗口宿主）的站点页面上面再摆一条后退 / 前进 / 刷新 / 地址栏 / 浏览器设置 / 「网页 | 播放器」分段按钮 / 关闭的工具条。

站点格里标了「用播放页打开」的站点（Netflix 默认）点开直接进 2，不标的进 1；在 1 里点「用 Fushi 播放」又会进 2 的网页档。两者长得像、登录态以前还不通（#2730 已把 cookie 罐 / user data folder 合成一份），用户分不清自己在哪个浏览器。

## 目标

- 用户能看到的「浏览器」只有 app 内浏览器的标签页外壳；登录、选剧、选集、地址栏、站点设置全部在这里。
- 视频页只当播放器：只在站点的观看页、且页面里有视频时出现；离开观看页 / 返回就回到**同一个浏览器标签页**（地址、历史、登录一致）。
- 浏览器工具条按页面内容给一个上下文按钮：视频 →「用 Fushi 播放」，漫画 / 小说 →「用 Fushi 阅读」。三者同一个入口模型、同一套文案，替代视频页的「网页 | 播放器」分段按钮。

## 不做什么

- **不把窗口宿主 WebView2 塞进浏览器标签页。** 标签页的 WebView 是捕获合成（纹理）出来的，DRM 画面在捕获里是纯黑，4K 捕获卡（`webBrowserWatchPageNeedsPlayer` 的注释）；底层合成是垫在 Flutter 下面的子窗口，一个进程同一时刻只能有一个持有者（`acquireUnderlayComposition`），还要求它上面的路由页底透明。把它做成「标签页的一种」需要标签页外壳整页透明、工具条改成浮层、标签切换时交接 HWND——代价大且与标签页的多 WebView 模型冲突。所以底层合成仍由视频页（一张盖在浏览器上的路由）持有，**但视频页不再有自己的浏览 UI**，用户感知上它就是浏览器里「全屏播放这一集」的那一层。
- 不改制卡重放（可捕获档 `web_video_fushi_page.dart`）的逐句重放逻辑。
- 不改五端其它平台的行为：没有底层合成的平台本来就只有浏览器（`webVideoSitesAvailable` 只在 Windows 为真）。

## 设计

### 1. 承载方式：浏览器标签页 + 盖在上面的播放器层

```
浏览器标签页（选集页）──观看页──▶ PlayInFushiFeature 交接
        ▲                              │ 按住标签页媒体、Netflix 退回选集页
        │                              ▼
        │                      VideoFushiPage（底层合成，只有播放器档）
        │                              │
        └──── 返回 / 离开观看页 ◀──────┘
              （离开去的地址交回标签页加载）
```

- 底层合成的 WebView2 仍用窗口宿主 env；#2730 起它与浏览器共用同一个 user data folder，所以登录、站点设置（广告拦截 / 网页深色 / 站点权限）天然一致，播放器层不需要自己的登录导入 / 设置入口。
- 播放器层的档位从「网页档 / 播放器档」二选一改为**只有播放器档**：
  - 有视频且不在站点弹层（`isBlocked`）里 → 播放器控件。
  - 页面还没有 `<video>`（观看页刚开、Netflix 在缓冲）或站点弹层打断（「还在看吗？」）→ 站点页面露出来让用户点，上面只有一条**细返回条**：返回、标题、「在浏览器中打开」。没有地址栏、前进、刷新、分段按钮。
  - 地址离开观看页（`webVideoIsWatchPage` 为假：Netflix 片尾跳回浏览页、YouTube 跳出 watch）→ 播放器层自动关掉，把那个地址交回浏览器标签页（见下）。
- 返回键：播放器层任何状态下都是「关掉本层」，不再一级一级退网页档历史（`webVideoBackAction` / `WebVideoBackAction` 删除）。

### 2. 回到同一个标签页：`WebVideoBrowserReturn`

播放器层和标签页之间只有一个单槽交接（`media/video/web_video_browser_return.dart`）：

- 播放器层因离开观看页 / 点「在浏览器中打开」而关闭时，把目标地址写进槽。
- `PlayInFushiFeature._releasePageWhenBack` 本来就在等浏览器路由重新在最上面（`untilRouteIsCurrent`，能跨过制卡重放的 `pushReplacement` 链），这时取槽：地址与标签页当前地址不同就在**这个标签页**里加载它（进历史，标签页后退还能回选集页）。
- 不是从浏览器交接来的播放器层（从视频库打开某一集网页书）离开观看页时没有浏览器可回：`pushReplacement` 一个浏览器路由打开该地址。这是唯一新开浏览器的地方，用户看到的仍是同一个浏览器外壳。
- `webBackToBrowser` 要跟着制卡重放往返：`WebVideoFushiPage` 新增 `returnToBrowser`，换回 `VideoFushiPage` 时原样带回，否则重放后离开观看页会在旧浏览器上再压一个浏览器。

### 3. 现有入口迁移

| 入口 | 以前 | 以后 |
|---|---|---|
| 站点格（浏览器起始页 / 浏览器首页）点站点 | 标了 `openInPlayer` → `openInWebVideoPlayer` 进视频页网页档 | 一律在浏览器里打开站点 |
| 站点 `openInPlayer` 标记 | 「默认用播放页打开」 | 「观看页自动用 Fushi 播放」：该站点（同 host）的观看页由 `PlayInFushiFeature` 自动交给播放器层（Netflix 不看标记，浏览器里本来播不了）。持久化字段 `player` 冻结不改名 |
| `openInWebVideoPlayer` | 打开站点首页或当前网页 | 只给 `PlayInFushiFeature` 交接**观看页**用（`backToBrowser` 恒真，参数删掉） |
| `webBrowserSiteOpensInPlayer` | 站点格判据 | 删除；换成 `webBrowserSiteAutoPlays(sites, url)` |
| 「用 Fushi 播放」在 Netflix / YouTube 非观看页 | 整页交给视频页网页档 | 不给（交过去也会立刻因离开观看页关掉）；其它站点照旧 |
| 视频页「网页 \| 播放器」分段按钮、网页档工具条、播放器档右上「回到网页」 | 切档 | 删除；回浏览器就是返回键 |
| 视频页网页档「从浏览器导入登录」 | 视频页自己一份 | 删除（浏览器的登录导入功能写同一个 cookie 罐）；`WebVideoLoginImport` 连同测试删除 |
| 视频页网页档「浏览器设置」 | 推浏览器设置页 | 删除（浏览器 ⋯ 菜单里就有） |
| 迁移旧「视频站点」偏好 `settleLegacyVideoSites` | 标成播放页 | 不变（标记含义顺延为自动播放） |

### 4. 上下文按钮：一个入口模型

新增 `web_browser/features/open_in_fushi/`：

- `WebPageContentKind { video, comic, novel }` 与纯函数 `classifyWebPageContent(WebPageContentProbe)`：探针是一段只读 JS（大视频数、长图数、正文字数），每次主框架加载完 / 单页应用换页 / 标签页回到前台时跑一次，结果按标签页缓存，变了经 `actionsChanged` 让壳重建工具栏。
- `WebPageContentFeature`：持有探针与缓存的功能；`buildWebBrowserFeatures` 里建一份，传给三个功能。
- `webOpenInFushiAction(kind:, primary:, busy:, onPressed:)`：三个功能都用它造动作——同一套 id（`open_in_fushi.<kind>`）、图标、优先级与文案：
  - 页面内容就是这一类（`primary`）→ 放工具栏，文案「用 Fushi 播放」/「用 Fushi 阅读」，优先级 80（工具栏放不下按优先级收进「⋯」，复用壳的 `adaptiveOverflow`）。
  - 不是 / 认不出 → 收在「⋯」里，文案带类别：「用 Fushi 播放」/「作为漫画用 Fushi 阅读」/「作为小说用 Fushi 阅读」——探针认错时用户仍够得到。
- 视频的「primary」：YouTube / Netflix 观看页按地址判；其它站点按探针（页面里有大视频）。
- 漫画 / 小说的旧文案 `manga_web_chapter_read`、`novel_web_page_read` 由 `i18n_sync` 删除，新 key 见实现。

### 5. 动效

- 播放器层的细返回条与播放器控件之间切换用 `AnimatedSwitcher`（`fushiMotionDuration`），墨水屏 / 减弱动态效果自动归零。
- 工具栏上下文按钮随页面内容出现 / 换类别走壳现有的工具栏动作动画；没有新增动效常量。

### 6. 制卡重放不受影响

- 播放器层的制卡入队、空闲自动制卡、`_runWebMineQueue` 换到可捕获档、`WebMineReturnState` 回放全部不动。
- 唯一改动是 `returnToBrowser` 的往返（见 §2）。

## 已知限制

- 非 Netflix / YouTube 站点没有可靠的「观看页」地址形状（`webVideoIsWatchPage` 对它们恒真），播放器层在这些站点里站内换页不会自动关；用户按返回即回浏览器。
- 探针只在加载完 / 换页 / 回前台时跑，懒加载很晚的漫画页第一次可能认不出（按钮在「⋯」里），刷新或换页后纠正。
