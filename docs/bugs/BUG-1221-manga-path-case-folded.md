## BUG-1221 · 漫画页图解析把路径折成小写，制卡封面名被小写化且大小写敏感平台缺页

- **报告**：2026-07-28（BUG-1218 审查时点名、划在范围外的「第 10 处」，现单独修）
- **真实性**：✅ 真 bug（同款模式，根因 `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:346` `resolveMangaResource`）

### 根因

`p.canonicalize` 在 **Windows** 上会把整条路径折成小写（`path` 包
`lib/src/style/windows.dart:181` `canonicalizePart(part) => part.toLowerCase()`；
POSIX style 无此覆写，见 `lib/src/internal_style.dart:89`——**macOS / Linux /
Android 上并不折**）。`resolveMangaResource` 此前直接把 canonicalize 的结果当**返回的
真实路径**：

```
Vol1/P001.JPG   （漫画包里的真实条目，落盘时大小写原样保留）
vol1/p001.jpg   （解析后返回的路径）
```

漫画的落盘名确实保留原大小写——`MangaStorage.uniqueDestRel`
（`manga_storage.dart:88`）只把**去重键**转小写（"Windows 文件系统大小写不敏感，故用
小写键去重"，刻意为之），返回的 `candidate` 与写进 `manga.json` 的 `url` 都是原大小写。
所以磁盘条目与 manifest 一致，唯一折平的就是这个解析函数。

**影响面（如实界定，不夸大）**：

- **Windows**：文件系统不区分大小写，页图能读出来，**不缺页**。但返回值会**流出本次
  读取**——`_updateCurrentPageImagePath`（`:1350`）把它存进 `_currentPageImagePath`，
  制卡时经 `ensureMangaCoverPng`（对已有合法扩展名的路径**原样返回**）直接当 Anki 封面
  源路径，**媒体名因此被小写化**，与源文件名不一致。这是 Windows 上真实可观察的副作用，
  但不影响卡片显示。
- **大小写敏感平台（Android / Linux）**：`canonicalize` 不折大小写，所以**原生导入 +
  阅读不触发**。触发链与 BUG-1218 同类，是**跨平台数据搬运**：Windows 侧算出的小写路径
  一旦被持久化并搬到大小写敏感设备（备份还原 / 裸数据拷贝），`existsSync` 为 false →
  页图 404、制卡无封面。
- 因此本条属**正确性 / 防御性根因修**（消除"读写路径 ≠ 真实路径"这一整类隐患），
  **不是**修一个当前 Windows 上用户可见的缺页故障。原始 BUG-1218 曾把同类问题的故障链
  说成"Android 上原生解析整本失踪"，那个说法已在 BUG-1218 里更正，此处不重复该错误。

**逐处判定**（漫画链全仓扫 `canonicalize`，共 6 处）：

| 位置 | 判定 | 处置 |
|---|---|---|
| `manga_hibiki_page.dart:347/349` `resolveMangaResource` | **(甲) 当真实读写路径用** | ✅ 已改 |
| `manga_hibiki_page.dart:916/918` `_interceptRequest` 的 403/404 判别 | (乙) `candidate` 只进 `isWithin` 比较、不进 `File()` | ❌ 不改（本就是纯边界比较） |
| `hibiki_manga_ocr_host.dart:356/361` | (乙) 集合成员比较（`live.contains`），刻意的大小写不敏感 key | ❌ 不改 |
| `manga_storage.dart:88/91/106` `uniqueDestRel`（非 canonicalize，是 `toLowerCase`） | (乙) 刻意的大小写不敏感**去重键**，返回值已保留原大小写 | ❌ 不改 |

**无第 11 处**：漫画链其余路径构造（`:730` `mangaJsonPath`、`:739` `imagesDir`、
`:1488`）都是裸 `p.join`，从不经 canonicalize，本就保留大小写。

- **[x] ① 已修复** — `resolveMangaResource` 改为「**越界校验用 `p.canonicalize`**
  （折大小写，`../` 逃逸不被大小写差异绕过）、**返回值用 `p.absolute` + `p.normalize`**
  （同样绝对化并折叠 `.`/`..` 段，但保留大小写）」。与
  `EpubParser._resolveWithinExtract`（BUG-1218）、`_safeArchivePath`（TODO-739）同款。
  比 EPUB 侧多一个 `p.absolute`：本函数契约是返回**绝对**路径，而 `p.normalize` 与
  `canonicalize` 不同、**不会**绝对化——漏掉它会静默改变返回值语义。

- **[x] ② 已加自动化测试** — `hibiki/test/pages/manga_path_case_preserved_test.dart`：
  三种混合大小写条目（`Vol1/P001.JPG` / `CH02/Page_01.Jpeg` /
  `MixedCase/SubDir/IMG_0001.PNG`）的解析结果与 `listSync` 列出的**真实磁盘条目名逐字节
  比对**；URL 入口 `resolveImageUrlToFile` 与百分号编码条目同样覆盖；返回值绝对性被单独
  钉住（防 `p.absolute` 补偿被删）；穿越守卫三条负向用例（`../` 逃逸、解析到 root 外的
  真实文件、缺文件）确认大小写保留没削弱防护。

  **逐字节比对而非 `existsSync` 是刻意的**：本地跑在 Windows 上 `File.exists` 不区分
  大小写，只断言 `existsSync` 根本抓不到这个 bug。

- **[ ] ③ 未做真机复测** — 本机是 Windows（`adb devices` 为空，无任何 Android/Linux
  设备），恰好是这个 bug 页图不缺的平台。「大小写敏感平台上页图 404」这一结论由「解析出
  的路径与磁盘条目逐字节不符」推出，未在真机上复验。Windows 上的全绿**不能**当作已验证。

- **备注**：与 BUG-1218（EPUB 侧同款）、TODO-739（解压侧同款）构成同一结论的三处落地。
