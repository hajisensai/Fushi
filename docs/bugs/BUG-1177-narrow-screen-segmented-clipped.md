## BUG-1177 · 窄屏/小窗口下多处内容显示不全（说明文字、分段控件、书名、对话框标题）

- **报告**：2026-07-28（用户：修复各个地方在窄屏或小屏显示不全的问题，比如设置里面配置项的说明，下载，书的名字等。全部修复）
- **真实性**：✅ 真 bug。不是单点问题，而是同一个错误取向在多处共享组件里的复现：**把「不抛 RenderFlex overflow」当成了目标**。文字被钳成固定行数、控件被钳进固定像素、标题被允许压到 0 宽——这些都不会报错，但用户就是看不全内容。

### 根因清单（逐条 `file:line` 为修复前位置）

| # | 根因 | 位置 | 表现 |
|---|---|---|---|
| 1 | 说明文字硬钳 3 行 + ellipsis，且无逃生口 | `hibiki/lib/src/utils/components/settings_shared.dart:1823`（常量 `:40`） | 设置项说明尾部（路径、警告、生效条件）被吃掉。设置行只有 `minHeight`、行高自由，这个上限纯属自伤 |
| 2 | flexible trailing 被 `!trailingFlexible` 排除在窄屏堆叠判定外 | `settings_shared.dart:480-483` | 控件与 `Expanded` 标题按 flex 五五分，360dp 上标题只剩约 130px；不溢出但两边都读不了 |
| 3 | 裸 `SegmentedButton` | `torrent_settings_section.dart:286/334/508`、`anime_download_dialog.dart:1021` | Material 把每段钳到「可用宽/段数」并**静默裁字**，`qBittorrent` 等不可断行长词在 360dp 下只剩几个字符 |
| 4 | 对话框默认 `insetPadding` 硬编码 `horizontal: 40` | `hibiki_material_components.dart:1088` | 320dp 上正文只剩 240px，扣掉头部内边距与 52px 图标徽标后标题只剩约 144px，普遍被省略成「…」 |
| 5 | 页头标题允许被 actions 压到 0 宽 | `hibiki_material_components.dart:1783` | 窄屏 4~5 个图标就能让页面标题彻底消失（不报错，就是没了） |
| 6 | 工具栏动作区上界取**整窗宽** × 0.48 而非本行约束 | `hibiki_material_components.dart:2005` | 脚手架嵌在分栏/受限宽面板里时会真 overflow |
| 7 | AppBar 挂 4~5 个动作且无窄屏折叠 | `media_collection_detail_page.dart:249`、`media_collection_grid_detail_page.dart:334` | 320dp 上动作 + 返回键吃掉约 296px，合集名只剩二十几像素 |
| 8 | 卡片标题 `maxLines: 1` + 文字块死高 | `home_video_page.dart:3332/2568/2753`（`_kVideoCardTextBlock = 52`）、`galgame_poster_card.dart:88`、`home_dashboard_page.dart:1142`（`_kContinueRowHeight = 196`） | 窄屏卡宽仅约 136~154px，一行只看得到日文书名/剧名/游戏名的开头几个字 |
| 9 | 网格几何写死比例 | `games_library_page.dart:886/944`（`0.62` 抄了两遍） | 按「3:4 封面 + 一行标题」估出来的比例，320dp 上文字区只剩约 38px，物理上放不下两行 |
| 10 | 书架卡 footer 死高 40px 装两行 12sp | `shelf_card_widgets.dart:25` | `textScale ≥ 1.25` 时书名第二行下半截被 `SizedBox` 切掉 |
| 11 | 历史卡标题条高度是纯比例 `maxHeight * 0.25` | `history_reader_page.dart:123` | 与里面两行文字毫无关系；窄屏 cell 只剩约 48px，大字号即裁字 |
| 12 | 会真抛 RenderFlex overflow 的按钮行/固定高 | `interconnect.part.dart:1056`、`backup.part.dart:445/560`、`media_sources_dialog.dart:149/362`、`mokuro_moe_tasks_section.dart:62`、`mokuro_moe_catalog_dialog.dart:218` | 令牌操作按钮、备份选择计数行、来源对话框页脚、任务列表死高 220、目录对话框死高 440 |
| 13 | 统计汇总卡写死双列，无窄屏回退 | `reading_statistics_page.dart:541/565`、`video_statistics_page.dart:229/255` | 320dp 上每格只剩约 100px 文字宽，而每格要放 7 行「标签: 数值」，每行都被迫折行。同页 `_buildMidSection` 早有窄屏堆叠，汇总卡一直漏了 |
| 14 | 下载页 TabBar 均分宽度 | `downloads_page.dart:59` | 窄屏 + 大字号下较长 tab 名（英文 `Subscriptions`）被裁 |

### 修复取向

不是逐点打补丁，而是先修共享组件的根因（1/2/4/5/6 一改多治），再收口重复几何（9 的两处 `0.62`、3 的四处裸分段条），最后处理确会抛异常的点（12）。新增两个共享件消除「同一问题两套写法」的特殊情况：

- `HibikiSegmentedStrip`——把设置行里早已存在（BUG-008）但私有的「装不下就横向滚动」契约开放给任意调用点。
- `narrowAwareAppBarActions` + `HibikiAppBarAction`——窄屏把次要 AppBar 动作折进溢出菜单，动作一个不少，只是多一次点击。

### 两处需要留档的权衡

1. **`HibikiListItem.titleMaxLines` 默认值保持 1，没有改。** 曾改成 2（列表项承载的正是书名/视频名/词典名），但 golden `list_tile_narrow` 在 150×80 的固定高度盒子里直接渲染出 overflow 红条——相当多调用点把它放在固定高容器里，改默认会连带撑破。改为逐调用点显式放宽（下载任务行、订阅行、互联 URL / 对端 / 局域网设备、漫画任务），结论写进了该字段的文档注释。
2. **视频卡标题两行 vs BUG-943 的卡底空白。** BUG-943（用户实报「底部多显示了一块」）的根因是文字块**死钳 83px** 的最坏预留；当时的修法是收敛到 52 并把标题钳成单行，代价就是本 bug 的「名字显示不全」。现在文字块高度按真实行高**算出**（默认字号约 66），不再是任何一个猜出来的常量：BUG-943 抱怨的 50px 空白没有回归，短标题卡只多约 14px——这是让长标题能显示第二行必须付的最小代价。守卫测试里已完整留档，便于一句话回退。

### 未纳入本次修复（如实记录）

- Cupertino renderer 的单行标题（`cupertino_settings_renderer.dart:55`，`CupertinoListTile` 由 Flutter SDK 强制 `maxLines: 1`）与 `settings_shared.dart` Cupertino trailing 按屏宽 0.42 限宽：Cupertino 仅为隐藏内部能力（`auto` 下五平台统一走 MD3），非用户可见路径。
- `profile_management_page.dart` / `dictionary_settings_dialog_page.dart` 的 trailing 挂 4~5 个控件：已被根因 2 的窄屏堆叠覆盖（不再与标题抢宽），但更彻底的做法是把它们收进溢出菜单。
- `anime_download_dialog.dart` 集号输入框固定 96px、`galgame_home_page.dart` 卡片固定 126px 高：影响面较小，未在本轮处理。

- **[x] ① 已修复** — `e0ca57a80`（共享组件根因 + 会抛异常的按钮行）、`88df6f8e2`（媒体名称单行截断 + 死高/死比例）、`1a8b51ce7`（游戏名/统计卡/AppBar 标题）、本轮末次提交（历史卡标题条、TabBar、测试）
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/narrow_screen_overflow_test.dart`（13 例，逐条锚定根因 1/2/3/4/7/10：说明文字不再钳行数且逃生口仍生效、窄行 flexible trailing 堆叠且宽行不误堆叠、分段条装不下即滚动且装得下不引入多余滚动、对话框边距窄屏收窄/宽屏不变/显式值优先、AppBar 折叠后三个动作仍在菜单里、footer 高度随文字缩放变高）。另更新两处既有守卫：`test/settings/settings_redesign_static_test.dart` 改守「subtitle 由 opt-in 覆盖决定行数，旧的无条件 3 行钳制必须保持消失」；`test/pages/video_card_cover_aspect_guard_test.dart` 改守「文字块高度必须按真实行高算出、不得退回硬编码常量」并留档 BUG-943 权衡。
- **备注**：全部改动在 worktree `fix-narrow-screen-overflow` / 分支 `worktree-fix-narrow-screen-overflow`，基底 `7a6df694b`（origin/develop，比本地主 checkout 领先 22 个 commit——调查子代理给的行号来自落后的主 checkout，均已在 worktree 内重新核对）。真机验收未做：布局类改动应在真实设备上按 320/360/400dp 与 textScale 1.0/1.5 各看一遍。
