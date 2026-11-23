# 有声漫画导出包格式（已实现）

> 状态：已实现（拍板台 `design-manga-audio-export-pkg`，来源拍板 bnAC_eferQ-2 (a)）。
> 本文是格式与流程的真相源；实现与设计稿的偏差、待定项的取舍见 §9。

## 1. 要解决的事

用户在一台 Fushi 上把一卷 / 一个系列的漫画做成有声版（标注 → 复核 → Irodori 等逐句生成，很慢），
希望在另一台 Fushi 上**不重新生成**就能直接播放：工作台「导出有声漫画」（单卷 / 按系列多选），
另一台直接导入；导入导出都能走 CLI。

已有的闭环只有一半：`tts import <key> <manifest.json>`（`tts.manga.import`，与漫画卡「导入漫画有声」
同一套校验）能把**本机已有的一卷**登记上一份外部成品清单，但：

- 不带页图、OCR、演出稿、系列选角，目标设备必须先有同一卷（同页数、同 OCR 签名）；
- 只登记、不复制音频，清单里的音频相对路径要靠用户自己把整个目录搬过去；
- 系列档案（角色表、声音指派、用词替换表、成员顺序）完全不跟着走。

导出包就是把这几样按现有格式原样打包，加一份包清单把路径和身份重建规则写清楚。

## 2. 现有格式（导出包直接复用，不另起一套）

| 内容 | 本机位置 | 格式 / 定义处 |
|---|---|---|
| 页图 + OCR | `EpubBookRow.extractDir` 下的页图与 `epubPath` 指向的 `manga.json` | `MokuroPayload`（`parseMangaJson`），OCR 签名 `mangaPayloadOcrSignature` = `MangaOcrMetadata.engineSignature` |
| 演出稿 | `<db>/tts_cast/<sha1(bookKey)>.manga-script.json` | `MangaAudioScript`（`manga_audio_script.dart`，行键 `p<页>b<块.块>`，含 `ocr` 签名） |
| 成品清单 + 逐句音频 | `<db>/manga_audio/<sha1(bookKey)>/manifest.json` + 同目录音频 | `MangaRenderManifest`（`v`=1，`pageCount` / `ocr` / `cont` / `lines[{id,p,b,s,k,beat,f,ms,t,sp,ph,voice,seed,shape}]` / `pages`），`f` 相对清单目录 |
| 广播剧 / 动画音轨成品 | `<db>/manga_drama/<sha1(bookKey)>/manifest.json` + 每段一个文件 | 同上，`cont: true` |
| 系列档案 | `<db>/tts_cast/<sha1(seriesKey)>.series-cast.json`，书 → 系列关联在同目录 `series-links.json` | `SeriesCastProfile`（`roster` / `voices` / `seed` / `members` / `subs` 用词替换与人名读法 / `title`） |
| 未配音账本、标注失败账本 | `<db>/tts_cast/<sha1>.voicing.json` / `.manga-annotate.json` | 不导出（见 §4） |

关键事实：成品清单里的音频路径**已经是相对清单目录的**（`mangaAudioLinePath` = `join(清单目录, f)`），
所以只要清单和音频按原相对位置放在一起，换机器不用改清单内容；需要重建的只有 bookKey、seriesKey
和库里的绝对路径（`Audiobooks.alignmentPath` / `audioPathsJson`，由 `registerMangaAudio` 生成）。

## 3. 包结构

一个包 = 一个 zip（扩展名 `.fushi-manga-audio`，内部是普通 zip，便于人工检查），stored（不压缩）
音频与页图（本来就是压缩格式，再压只浪费时间），JSON 用 deflate。

```
package.json                      包清单（§3.1）
series/<sid>.series-cast.json     每个涉及到的系列一份（原文件原样，seriesKey 见 §5）
volumes/<vid>/
  pages/…                         页图，按 manga.json 里 images[].path 原相对路径
  manga.json                      MokuroPayload 原样
  script.json                     演出稿原样（MangaAudioScript）
  audio/manifest.json             成品清单原样（MangaRenderManifest，f 相对此目录）
  audio/<f>…                      清单引用的每个音频文件
  drama/manifest.json             可选：广播剧成品（同上）
  drama/<f>…
```

`<vid>` / `<sid>` 是包内序号（`v1`、`v2`…，`s1`…），不是 bookKey / seriesKey 的哈希：
包里不出现源设备的绝对路径或本机身份，导入时一律重建（§5）。

### 3.1 `package.json`

```json
{
  "format": "fushi-manga-audio",
  "v": 1,
  "createdAt": 1795000000000,
  "app": "fushi 1.x.y",
  "series": [
    { "id": "s1", "title": "…", "file": "series/s1.series-cast.json",
      "members": ["v1", "v2"] }
  ],
  "volumes": [
    {
      "id": "v1",
      "title": "…",
      "series": "s1",
      "pageCount": 192,
      "blocks": 900,
      "ocr": "<engineSignature>",
      "content": "<OCR 内容签名>",
      "manga": "volumes/v1/manga.json",
      "script": "volumes/v1/script.json",
      "audio": { "manifest": "volumes/v1/audio/manifest.json", "lines": 812,
                 "durationMs": 3456789, "active": true },
      "drama": null,
      "voices": ["irodori:<pack>/<group>", "voicevox:…"],
      "files": { "count": 1004, "bytes": 512345678, "sha256": "…" }
    }
  ]
}
```

- `pageCount` / `ocr` 与 `MangaRenderManifest.pageCount` / `ocr` 同值，导入前就能用现成的
  `mangaManifestVolumeMismatch` 判一致性，不用先解包。
- `content`：卷的 OCR **内容**签名（`mangaPayloadContentSignature`，按每页块数、块框与文字算，
  不看引擎签名）；`blocks` 是整卷 OCR 块数。认「本机同一卷」用它们，不用 `ocr`（§9）。
- `audio.active` / `drama.active`：源设备当前登记的是哪一份成品（两份都有时导入后登记同一份）。
- `voices`：清单与演出稿里出现过的声音 id（逐行 `voice` + 指派表解析结果）。**只用于「继续重配」
  前的缺失检查**，播放成品不需要声音模型。
- `files.sha256`：该卷全部文件按包内路径排序后逐个 `path\0sha256\n` 拼起来再取 sha256，
  用于判包损坏（不做逐文件校验列表，避免清单随行数膨胀；与 `migration_manifest.dart` 的
  整档哈希取舍一致）。
- 版本兼容：`v` 只在不兼容时加；读方认识的最大版本小于包的 `v` 时拒绝并提示升级。
  内部各 JSON 仍各自带自己的 `v`（`MangaRenderManifest.schemaVersion` 等），按各自现有的宽松解析读。

## 4. 导出

入口：工作台「导出有声漫画」（单卷，或系列下多选卷）；CLI `fushi tts export`（§6）；
操作目录 `tts.manga.export`（`op_descriptions_tts.dart` 写描述，只读本地、写一个新文件，
`OpRisk.irreversible`——只写一个文件，目标已存在时覆盖、没法撤销，与 `library.favorite.export`
同口径；失败 / 取消删掉半成品）。

规则：

1. 只导出**有登记成品**（`audiobookRowHasRegistration`）的卷；没有成品的卷只有演出稿时可选
   「仅演出稿」（不带 `audio/`），给另一台接着生成用。
2. 卷有未结束的标注任务 / 生成任务时不导出（与 `requireNotAnnotating` / `requireNotRendering` 同判据），
   提示等它结束——清单正在被改写。
3. 演出稿 OCR 签名与当前 OCR 不一致（`isStale`）时照样导出，但 `package.json` 里标
   `"scriptStale": true`，导入方提示「要重新标注」。
4. 清单引用的音频缺失时整卷失败，列出缺失文件（与 `checkMangaAudioManifest` 同口径），不打残包。
5. 不导出：未配音账本（本机生成状态，另一台没意义）、标注失败账本、AI 提供方配置与密钥、
   声音模型 / 参考音频本身（体积大、可能有授权限制，§7）、阅读进度。
6. 系列档案按原文件导出，`members` 改写成包内 `<vid>`（只保留这次导出的卷，保持原顺序）。

## 5. 导入与路径 / 身份重建

入口：漫画库「导入」识别 `.fushi-manga-audio`（`import_carrier.dart` 加一种载体）；
CLI `fushi tts import-package`（§6）；操作目录 `tts.manga.import-package`（执行前确认，
可撤销 = 删除本次新建的书与登记；对已存在卷的替换走现有 `confirm` 语义）。

逐卷：

1. **找目标卷**：按 `pageCount` + `content`（OCR 内容签名）+ 标题在本机库里找同一卷
   （`matchMangaAudioPackageVolume`；整卷没有 OCR 块时内容签名只剩页数，必须再标题一致）。
   - 找到且一致：不重复导入页图与 OCR，直接用本机这一卷的 bookKey；
   - 找不到：把 `pages/` + `manga.json` 当作一卷新漫画导入（走与 mokuro 导入同一个落库入口，
     新建 bookKey），再继续；
   - 找到但页数 / OCR 不一致：报冲突，让用户选「作为新卷导入」或跳过（不覆盖本机 OCR）。
2. **演出稿**：写到 `<db>/tts_cast/<sha1(新 bookKey)>.manga-script.json`（`MangaAudioScriptStore.save`），
   本机已有演出稿时要确认替换（与 `tts import` 的 `confirm` 一致）。
3. **成品**：把 `audio/` 整个目录复制到 `<db>/manga_audio/<sha1(新 bookKey)>/`（`drama/` 同理到
   `manga_drama/`），清单内容不改（`f` 本来就相对清单目录）；然后走现有 `checkMangaAudioManifest`
   + `registerMangaAudio` 登记。这一步与 `tts import` 共用同一套校验与登记，导出包只是多了
   「先把文件放到规范位置」。
4. **系列**：`seriesKey` 在本机重建——目标卷所在合集已有系列档案就**合并**（`mergeCastRoster`
   同名合并别名、声音指派只补本机没设的、用词替换按 `from` 去重追加），没有就以
   `collection:<本机合集 id>` 新建；新导入的卷进合集并按包里 `members` 顺序加入 `members`
   （与现有系列关联规则一致，书 → 系列写 `series-links.json`）。
5. **声音缺失检查**：导入不需要声音就能播放；只在用户之后要「继续重配 / 单句重生成」时，
   按 `volumes[].voices` 与本机 `ttsProductionPresets` 比对，缺的列出来引导去装声音包
   （提示，不拦导入）。
6. 失败回滚：每卷在临时目录解包、校验通过后再原子移动到规范位置并登记；某卷失败不影响其它卷，
   结果按卷列出（导入了 / 跳过 / 冲突 / 失败原因）。

## 6. CLI

与现有 `tts` 命令组并列（`packages/fushi_cli/lib/src/commands/tts_commands.dart`），走 ctl 路由：

```
fushi tts export <key>... --out <file.fushi-manga-audio> [--script-only]
fushi tts export --series <seriesKey 或合集> --out <file> [--volumes <key,...>]
fushi tts import-package <file.fushi-manga-audio> [--as-new] [--yes] [--dry-run]
```

- `--dry-run`：只解析 `package.json`、做 §5.1 的匹配和冲突检查，打印每卷会怎么处理，不写任何东西。
- `--yes`：本机已有演出稿 / 成品时替换（同 `tts import --yes`）。
- `--as-new`：冲突卷一律作为新卷导入。
- 路径参数在 CLI 侧转绝对路径（同 `tts import` 现有做法）。
- 现有 `tts import <key> <manifest.json>` 保留不变：它是「本机已有这一卷，只登记外部清单」的低层入口，
  导出包导入在第 3 步内部复用它的校验与登记。

## 7. 风险与待定

- **体积**：页图 + 逐句音频，一卷常见 0.3–1 GB。导出放后台任务（进度、可取消），写临时文件再改名。
- **版权**：包里有页图。只做本人设备之间搬运，不做上传 / 分享链接 / 在线分发；导出界面写明用途。
- **声音授权**：不打包声音模型与参考音频（Irodori 声音包等可能有授权限制），所以导入方要「继续重配」
  时必须自己有同名声音，否则只能换声音重生成。
- **大包内存**：zip 读写一律流式（不整块载入），沿用 `migration_*` 的经验。
- **schema 漂移**：`MangaRenderManifest` / `MangaAudioScript` 已有宽松解析与 `v` 字段；导出包只在
  外层加 `package.json`，内部文件原样，新版本读旧包走现有兼容路径。
- 待拍板：包扩展名（`.fushi-manga-audio` 还是通用 `.fushi-pack`）；系列合并冲突（同一角色两边
  声音指派不同）时是否让用户逐条选——本稿默认「本机已设的优先，包里的只补空」。

## 8. 实现切分（排期用）

1. 引擎（`packages/fushi_engine`）：`MangaAudioPackageManifest` 解析 / 序列化 + 卷匹配纯函数 + 测试。
2. App：导出服务（后台任务、流式 zip）+ `tts.manga.export` 路由与描述 + CLI `tts export`。
3. App：导入服务（临时目录解包 → 匹配 → 落库 → 复用 `checkMangaAudioManifest` / `registerMangaAudio`）
   + `tts.manga.import-package`（确认、可撤销）+ CLI `tts import-package` + 导入载体识别。
4. 工作台 UI：单卷 / 系列多选导出、导入结果按卷列出、缺声音提示（带动效，设计系统组件）。
5. 往返测试：导出 → 新库导入 → 页数 / OCR / cue 数 / 时长 / 系列角色表一致，单句重生成可用。

## 9. 实现记录（2026-11-23）

代码位置：

- 引擎：`packages/fushi_engine/lib/tts/manga_audio/manga_audio_package.dart`（包清单、路径安全、
  文件摘要、卷匹配、系列合并）；`MangaImporter.importFromMangaJson` 加 `pageSource`（包里解出的
  页图是一次性的，按 `disposable` 移入书目录）。
- App：`fushi/lib/src/media/manga/audio/manga_audio_package_{io,tasks,export,import,page}.dart`
  （isolate 流式写包 / 解包、进程级后台任务表、导出 / 导入服务、导出 / 导入页）；工作台第 4 步
  「有声漫画包」一节；漫画导入框识别 `.fushi-manga-audio`（`ImportCarrier.mangaAudioPackage`）后
  转交导入页。
- 路由：`fushi/lib/src/ops/ctl_tts_package_routes.dart`（`POST /api/admin/tts/manga-packages/export`、
  `/import`、`GET /tasks/:id`、`POST /tasks/:id/cancel`），描述在 `op_descriptions_tts.dart`
  （`tts.manga.export` / `tts.manga.import-package` / `tts.manga.package-task` / `tts.manga.package-cancel`）。
- CLI：`fushi tts export` / `import-package` / `package-task` / `package-cancel`（默认等任务结束，
  `--no-wait` 起了就返回）。

与设计稿的偏差：

1. **卷匹配不用 `ocr` 引擎签名**：OCR 自带引擎签名时 `mangaPayloadOcrSignature` 直接返回引擎签名，
   同一个引擎识别的所有卷都相同，按它认「同一卷」会把页数恰好相同的另一卷认成目标。清单因此多了
   `content`（OCR 内容签名）与 `blocks`；`ocr` 仍照写，供演出稿新鲜度判断。
2. **撤销用日志而不是「只删新建的书」**：每次导入在 `<db>/manga_audio/_undo/pkg-<runId>/` 写
   `journal.json`，并备份被替换的演出稿与成品目录、记下导入前的有声登记与系列档案；撤销按日志
   删新建的书、恢复演出稿 / 成品 / 登记 / 系列档案与合集归属。只留最近 5 次（`kMangaPackageUndoKeep`）。
   这样「替换已有卷的演出稿 / 成品」也能撤销，而不只是新建的书。
3. **取消的边界**：导出全程可取消（杀掉写包 isolate、删 `.part`）；导入在解包与校验阶段可取消，
   进入落库阶段后不能取消（`cancellable=false`，结束后可撤销）。
4. **文件校验**：每卷解出的文件按 `files`（数量、字节、整体摘要）核对，不符的卷判 `package_corrupt`、
   不落库，其它卷照常导入。zip 条目解压时逐条核对 CRC。
5. **移动端导出**：写到临时目录后走系统分享（桌面端用保存对话框选位置）。

待定项的取舍（按本稿默认）：扩展名用 `.fushi-manga-audio`；系列合并「本机已设的优先，包里的只补空」，
不做逐条选择。
