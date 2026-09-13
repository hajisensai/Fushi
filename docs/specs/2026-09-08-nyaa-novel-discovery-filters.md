# 发现页 Nyaa 小说源：做种排序、疑似漫画标记、Nyaa 过滤三态

状态：设计稿（2026-09-08），等用户确认后实施。对应用户报告：Fushi 里下小说时，nyaa 源在【发现】里搜到的有些其实是漫画，而且小说种子死种多。

## 0. 已核实的事实

- 小说域映射到 Nyaa 分类 `3_0`（Literature 全部，`app_model.dart:4714`，全应用唯一一处决策）。Nyaa 的 3_1 英译 / 3_2 非英译 / 3_3 生肉里轻小说与扫图漫画、同人志图包混放，站方没有「小说 vs 漫画」维度。下游 `nyaa_discovery_source.dart:74-90` 零过滤直通，`categoryId` 被丢弃。
- 查询串只有 `q / c / f`（`nyaa_client.dart:475-483`），Nyaa 默认按发布时间倒序；结果页不排序、不过滤，只把 `↑seeders` 拼进副标题。
- **RSS 强制忽略排序**：nyaa 后端 `search.py` 两处写死（ES 路径 "Only allow ID, desc if RSS"，DB 路径 "Force sort by id desc if rss"），且只返回 75 条、忽略分页；实测同参数 RSS 首条做种 34、HTML 首条 288。HTML 搜索页尊重 `s=seeders&o=desc`。关键词搜索走 Elasticsearch 最多 1000 条（14 页），无关键词浏览最多 100 页。响应 gzip。
- Nyaa `f`：`0` 全部 / `1` 排除 remake / `2` 仅 trusted / `3` 仅完结批次（后端有、UI 不露出、无文档）。HTML 行颜色优先级 `deleted > hidden > remake(红) > trusted(绿)`，trusted 用户的 remake 只显示红，trusted 信息被吞；RSS 独立给 `nyaa:trusted` / `nyaa:remake`。
- 别人怎么做：Jackett/Prowlarr 的 `nyaasi.yml` 把 3_x 一律映射成 Books(7000)，不区分小说/漫画，暴露 `filter-id`（默认 0）与 `sort`，2 秒/请求节流；`lnrelease-discord-bot` 逐条抓 `/view/<id>` 文件列表只留含 `.epub` 的；`chaptr` 用出版社/发布者词表且自注「不过滤时 Literature RSS 约 98% 是漫画」「stick/lucaz 假阳性高」；Kavita/myne 以 `(Digital)` 等括号标签识别漫画。**没有现成的成熟分类器**。
- 命名规范（wotaku）：括号形状即类型——`()` 漫画、`{}` 条漫、`[]` 轻小说。漫画 `Title v01 (2021) (Digital) (1r0n).cbz`，LN `Title v01 [Yen Press] [Stick].epub`。
- 体积（实测 3_1/3_2/3_3 各 75 条 + LN 合集 5654 文件）：LN EPUB 每卷 p50 14.8 MiB、p99 45 MiB；英文数字版漫画 70–500 MiB/卷（典型 150–350）；日文生肉漫画 50–220；重叠区 30–60 MiB。3_1 做种榜前 75 条约 54 漫画 / 21 小说。
- 0 做种：所有交互式 UI（Nyaa 官方、AnimeTosho、qBittorrent 插件、Beastwick TUI）都不隐藏，只沉底/灰显；只有 Sonarr 这类全自动抓取默认 `MinimumSeeders = 1`。

## 1. 首屏走 HTML + 服务端按做种排序

- `NyaaClient` 搜索统一走 HTML 搜索页（`_parseNyaaHtmlSearch` 已能解析 seeders / leechers / category / 行颜色），新增 `sort` / `order` 参数，默认 `s=seeders&o=desc`；`page=rss` 分支只保留 `parseNyaaRss` 给测试与旧调用方，不再作生产首屏。
- HTML 行 class 映射：`success` → `trusted = true`，`danger` → `remake = true`（文档注明 remake 会盖掉 trusted）。
- 分页上限：关键词搜索 14 页 / 浏览 100 页，越界返回空而不是抛错。
- 请求节奏对齐 Jackett：同一 host 至少间隔 2 秒。

## 2. 做种数：排序 + 「隐藏无人做种」

- `DiscoveryResourceItem` 已有 `seeders` / `leechers`；新增 `category`（Nyaa `categoryId`）、`trusted` / `remake`。
- 源内按做种降序（服务端已排；本地再做稳定排序兜底），跨源仍按 source priority 串接不打乱。
- 新偏好 `discovery_hide_zero_seeders`（bool，**默认开**，用户 2026-09-08 拍板；调研显示交互式 UI 通行做法是不隐藏只沉底，记录为反对意见）。发现页筛选条给一个可切换 chip；隐藏时显示「已隐藏 N 条无人做种」一行，点一下即显示。未隐藏时 0 做种条目灰显。

## 3. 疑似漫画标记（默认开启的过滤开关，不硬删）

- 纯函数 `classifyNyaaLiterature({title, sizeBytes, categoryId})` → `manga / novel / undecided / audiobook`，放 `fushi/lib/src/media/discovery/nyaa_literature_classifier.dart`。先 `html.unescape`，正则不区分大小写。打分：漫画分 M、小说分 N；`M − N ≥ 2` → manga；`N − M ≥ 2` → novel；其余 undecided（**保留显示**）。

**强漫画 +3**

| 判据 | 正则 |
|---|---|
| 括号源标签 | `\((Digital(?:-[\w ]+)?\|c2c\|Scans?(?:ned)?\|Colou?red(?: Manga\| Comics)?)\)` |
| 容器名 | `\b(cbz\|cbr\|cb7\|cbt)\b` |
| 类型词 | `\b(Manga\|Manhwa\|Manhua\|Webtoon\|Doujinshi?\|Scanlations?\|Tankobon\|Omake\|One-?shot)\b`；日文 `一般コミック\|コミック\|漫画\|週刊\|月刊\|雑誌\|ジャンプ\|マガジン\|サンデー` |
| 章节编号 | `\b(?:c\|ch\|chapter)\.?\s?\d{1,4}(?:\.\d)?\b`、`\b\d{3,4}\s*[-–~]\s*\d{3,4}\b`、`\d{3}-\d{3}\s+as\s+v\d{2}` |
| 周更包 | `Weekly .*Chapter Updates\|\bWeek \d{1,2}\b` |

**中漫画 +2**：年份括号后接括号 `\(\d{4}(?:-\d{4})?\)\s*\(`；图片格式 `\b(JXL\|JPEG-?XL\|WebP)\b`；漫画专属组 `\b(1r0n\|\w+-Empire\|\w+-DCP\|Shizu\|Kaos\|Rillant\|Trite\|0v3r\|Colored Council\|PapriKa\+\|Chromatique\|aKraa\|Kileko)\b`；版本词 `\b(Omnibus\|Deluxe Edition\|Perfect Edition\|Master Edition\|2-in-1)\b`。

**强小说 +3**

| 判据 | 正则 |
|---|---|
| 类型词 | `\b(Light ?Novels?\|LNs?\|WN\|Web Novel\|Ranobe)\b`、`(?<!Graphic )\bNovels?\b`、`ライトノベル\|ラノベ\|一般小説\|小説\|轻小说\|輕小說` |
| 电子书格式 | `\b(EPUB\|AZW3?\|MOBI)\b` |
| LN 专属出版社 | `\[?(Yen Press\|Yen On\|J-?Novel Club\|Cross Infinite World\|Tentai Books\|Hanashi Media\|One Peace Books\|Sol Press\|Airship)\]?` |
| LN 专属发布者 | `\b(CleanBookGuy\|faratnis\|Antithetical\|Zaphkiel\|vgperson\|Skeweds\|Mochiguma\|SpicyEPUBs\|Baka-Tsuki\|LNWNCentral)\b` |

**中小说 +2**：尾部连续方括号且不含年份 `(\[[^\]\d]{2,}\]\s*){2,}$`；双栖出版社在方括号内 `\[(Seven Seas(?: Siren)?\|Vertical\|Kodansha\|Viz\|Square Enix\|Dark Horse)\]`；JNC 分级 `\b(Premium\|Prepub)\b`；阅读平台 `\b(Kobo\|Kindle(?:HQ)?\|iBooks\|Google Play)\b`。

**中性 / 弱**：`PDF` 小说 +1；`BookWalker` 小说 +1；`LuCaZ / Stick / Ushi / Oak / nao` **0 分**（两种都发，只能靠括号形状）；`v01`、`v01-v10`、`第NN巻`、`Complete`、`[English]`、前导 `[Group]` 全部中性；`Audiobook|MP3|M4B|FLAC|M4A` → audiobook，不参与判定。

**体积规则**（先从标题解析卷数 n；标题含 `Collection|Pack|Dump|Anthology|Bundle|SiteRip` 或 n 解析失败且总体积 > 2 GiB 则跳过）：每卷 < 25 MiB 小说 +2；25–60 MiB 0；60–150 MiB 漫画 +2；> 150 MiB 漫画 +3；n 未知且单文件形态总体积 > 150 MiB 漫画 +2；n 未知总体积 < 30 MiB 小说 +1。

- 应用点：`NyaaDiscoverySource` 映射层给小说域结果打 `contentHint`；发现页新偏好 `discovery_hide_suspected_manga`（bool，默认开）只隐藏 manga 档，undecided 保留；隐藏计数行同上。
- 不做逐条 `/view/<id>` 文件列表抓取（每条一次请求）；作为二期「点开详情时按需判定」。
- 语料测试：table-driven，正例/反例取自调研样本（`Sousou no Frieren v01-14 (Digital) (1r0n)` 漫画；`Re:ZERO v01-29 [Yen Press] [Stick]` 小说；`Kemono Jihen v01-21 (Digital) (Stick)` 漫画；`Youjo Senki v24-27 (2024-2025) (Digital) (Ushi)` 漫画——chaptr 语料把它错标成 LN，正是「发布组名不能当信号」的反例；`Gundam The Origin v01-24 (Digital) (BookWalker) (JP)` 漫画）。

## 4. Nyaa 过滤三态 + 徽标

- 新偏好 `discovery_nyaa_quality_filter`（int 0/1/2，**默认 0**，与 Nyaa UI / Prowlarr / Flexget 一致；只有 Sonarr 的全自动场景默认排除 remake）。发现页 Nyaa 过滤菜单：「全部 / 排除 remake / 仅信任发布者」，透传为 `f`。
- 卡片徽标：trusted 绿 / remake 红，来自 HTML 行 class。
- 不暴露 `f=3`。

## 5. 测试与验证

- `nyaa_client_test.dart`：HTML 首屏 + `s/o` 参数 + 行 class → trusted/remake + 越界页返回空。
- `nyaa_discovery_source_test.dart`：`category` / `contentHint` 透传；现有 `c=3_0` 断言保留（分类本身不改）。
- `nyaa_literature_classifier_test.dart`：规则表语料。
- `media_discovery_page_test.dart`：隐藏无人做种 / 隐藏疑似漫画两个开关的显示与计数行；Nyaa 过滤三态写穿偏好。
- 真机：Windows 上在发现页搜一个常见 LN 系列，截图对比开关前后。
