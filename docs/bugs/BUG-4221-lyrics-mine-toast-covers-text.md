## BUG-4221 · 歌词模式（平板）制卡结果小卡压住正文
- **报告**：2026-11-06（用户：应用内反馈 OOZ-lrCsU0，Android 平板歌词模式竖排小说；机器人代提）
- **真实性**：✅ 真 bug——`FushiToast.anchorMineToCorner` 的定位规则是把制卡结果小卡贴在歌词矩形**内侧**的底部起始角（旧 `fushi/lib/src/utils/misc/fushi_toast.dart:542` `_cornerGeometry`：`bottom = overlay 高 - 区域下沿 + 12`、`left = 区域左沿 + 12`）。歌词矩形就是正文区域，新版宽屏几何（`lyrics_player_modern_shared.dart` `LyricsModernWideGeometry`）里它横向铺满，竖排正文的列一直排到矩形底部，小卡必然压住左下几列。不是角落选错，而是「贴在正文区域里」这条规则本身就会挡字。
- **[x] ① 已修复** — 定位规则改成**让开正文区域**：新纯函数 `mineToastOffsetClearOf`（同文件）先试区域下沿之下的带子（紧贴下沿），再试上沿之上的带子，水平贴区域起始边（RTL 贴右）并夹在屏幕内；两边都放不下（正文真铺满整屏）才落进区域内。由 `CustomSingleChildLayout` 按卡片实测尺寸摆放，摆放层本身不命中，卡片外照样点穿。没有给歌词模式写特判：登记方只交「正文区域」，规则对所有登记方一致。
- **[x] ② 已加自动化测试** — `fushi/test/pages/mine_toast_test.dart`（下方 / 上方 / RTL / 铺满兜底四种几何的纯函数断言，widget 层断言卡片不与区域相交）；`fushi/test/media/audiobook/lyrics_player_mine_corner_test.dart`（真 `ReaderLyricsPlayerOverlay`，手机 390×844 与平板 1280×800 两个尺寸，小卡紧贴歌词 WebView 下沿之外、不相交）。改前均红。
- **备注**：新位置落在歌词下方的 chrome 带（时间读数 / 进度线一带），停留期间会盖住那一小段控件；这是「不挡正文」的代价。未在平板真机复测。
