# 卡组字段重新设计（2026-10-29 已采纳并实现，见文末「实现记录」）

2026-10-29 用户：「卡组字段名感觉不太符合，可以重新设计一下，比如卡片的图片字段，可以塞视频、gif。」
本文只出方案，等用户拍板后再实现。

## 1. 现状（已核对代码）

### 1.1 字段从哪来

- 内置笔记类型 **Fushi Card** = Lapis 全部 22 个字段（同名同序）+ 扩展字段 `SentenceTranslation`
  （`packages/fushi_anki/lib/src/fushi_card_note_type.dart`、`lapis_note_type.dart`）。字段名是 Lapis 的
  遗留名，沿用是为了「Lapis → Fushi Card 同名直映」。
- 制卡占位符映射 `defaultFieldMappings`（字段名 → `{expression}` 等占位符），Anki 目标与 Fushi 复习目标共用。
- **fieldId 由字段名派生**：`srsBuiltinFieldId(profileUid, 'fushi_card', fieldKey)`
  （`packages/fushi_engine/lib/srs/srs_builtin.dart`），挖词、词状态、同步日志都按它读写。
  所以**直接改内置字段的名字 = 换 fieldId = 旧卡的字段值、同步历史全部对不上**。这是本方案最大的约束。

### 1.2 「图片字段塞视频 / GIF」其实已经能装

- `Picture` 的映射占位符 `{card-image}`；消费卡片图片的占位符一族：`{card-image}` `{card-video}` `{book-cover}`
  `{video-clip}`（`AnkiHandlebarOptions.cardImageTokens`）。
- 视频制卡有四种图片模式 `VideoMiningImageMode`：`gif` / `currentFrame` / `subtitleStart` / `videoClip`
  （默认 videoClip，`fushi_engine/lib/mining/immersion_mining_request.dart`）；galgame 一键制卡默认出 GIF 或
  动态 WebP（`MiningAnimatedFormat`）。
- Fushi Card 模板的 `Picture` 位已经按「可能是 `<video>`」写样式并在元数据到达后重算尺寸
  （`templates/fushi_card/back.html:306`、`styling.css:555`）；Anki 侧有「视频模板适配」
  （`docs/specs/2026-10-04-anki-video-template-adapter.md`、`anki_video_template_service.dart`）。
- 因此缺的不是管线能力，而是：**字段名叫 Picture，用户（和别的工具）据此以为只能放静态图**；
  以及用户没有一个地方能明确选「这个字段放哪种媒体」。
- 未验证（方案落地前要实测）：AnkiDroid / AnkiMobile 对字段内 `<video>` 的播放与自动循环行为。

### 1.3 名字不符合的点（需要用户确认哪些最膈应）

| 现名 | 问题 |
|---|---|
| `Picture` | 实际可能是静态图 / GIF / WebP / `<video>`，名字只说图 |
| `MiscInfo` | 其实装「来源链接 + 片段时间」，名字什么都没说 |
| `SelectionText` | 弹窗里选中的文字，与 Sentence 的关系不直观 |
| `FreqSort` | 实为谐和频率排名，排序键 |
| `IsWordAndSentenceCard` / `IsClickCard` / `IsSentenceCard` / `IsAudioCard` | 四个布尔开关做卡型选择，Anki 里一排 `Is…` 字段占版面 |
| `DefinitionPicture` | 释义配图，默认不映射，和 Picture 并列容易混 |
| `Expression` | 对词条是「Term / Word」，Lapis 习惯名 |

## 2. 设计

### 2.1 把「字段键」与「显示名」拆开（先做，不可跳过）

内置字段新增两层：

- **稳定键** `key`：永远不改，继续作为 fieldId 的种子（现有 `Picture` 的键仍是 `Picture`）。同步日志、挖词读写、
  词状态都按它，旧卡零迁移。
- **显示名** `label`：用户在 Anki / 浏览页 / 模板编辑器里看到的名字，可以改，随语言本地化。

落点：`SrsFieldDef` 已有 `ankiNum`、名字作为单独可合并的字段键，改名本来就只是一条修改记录，不换 id
（`docs/specs/2026-10-14-fushi-srs-design.md` 结构编辑一节）；缺的是内置定义里把「ID 种子」和「名字」分开。

导出到 Anki 时字段名用显示名；回导时按 `ankiNum` / 稳定键匹配（既有规则）。

### 2.2 字段改名清单（草案，待用户逐项拍板）

| 稳定键（不变） | 新显示名 | 说明 |
|---|---|---|
| `Expression` | `Term` | 词条 |
| `ExpressionFurigana` / `ExpressionReading` / `ExpressionAudio` | `TermFurigana` / `TermReading` / `TermAudio` | 跟随 |
| `Sentence` / `SentenceFurigana` / `SentenceAudio` | 不变 | 已清楚 |
| `SentenceTranslation` | 不变 | 已清楚 |
| `Picture` | **`Media`** | 静态图 / GIF / 动态 WebP / 视频片段统一的「画面」字段 |
| `DefinitionPicture` | `DefinitionMedia` | 跟随 Media |
| `MiscInfo` | `Source` | 来源链接 + 片段时间 |
| `SelectionText` | `LookupSelection` | 弹窗里选中的原文 |
| `FreqSort` | `FrequencyRank` | |
| `Is*Card` 四个开关 | 保留，归到「卡型」组 | 模板在用，不拆 |

注意：现有用户的 Anki 笔记类型（Lapis、自建）字段名**不动**，只影响 Fushi Card 新建与导出。
Lapis 内置类型本身保持 Lapis 官方字段名（它是对官方牌组的兼容件）。

### 2.3 画面字段（Media）的明确语义

- 占位符统一成 `{card-media}`：由制卡时选择的模式决定内容——`image`（帧 / 字幕起点）、`animated`
  （GIF / 动态 WebP）、`clip`（`<video>`）。`{card-image}` `{card-video}` `{video-clip}` 保留为旧别名，
  只读不再生成（与现有 `cardImageTokens` 同族处理）。
- 设置里增加「画面字段放什么」一项（每个制卡来源可独立：视频默认 clip、galgame 默认 animated、
  漫画 / 书默认 image），取代现在散在高级制卡弹窗里的模式切换；弹窗里仍可临时覆盖。
- 模板：Fushi Card 的 `.fc-picture` 重命名为 `.fc-media`，按内容类型分派：`<img>` 点按放大，
  `<video>` 默认静音循环、点按有声播放（沿用现有尺寸重算逻辑）。
- 若所选目标（Anki 端）实测不能播放 `<video>`：降级写 GIF / WebP，并在设置页给一句说明，而不是静默写坏。

### 2.4 迁移

1. 只改显示名：旧卡的 fieldId、字段值、同步日志不受影响（稳定键不变）。
2. 已导出到 Anki 的 Fushi Card 笔记类型：下次「更新笔记类型」时按 `ankiNum` 改名，字段值保留
   （既有「更新笔记类型：管名字、CSS、模板正文」路径）。
3. 映射表：旧字段名 → 新显示名的映射在读取偏好时一次性迁移，占位符本身不变。
4. 模板里引用 `{{Picture}}` 等的位置随显示名改，用 `fushi_card_template_codegen` 重新生成并过现有同步守卫
   `fushi_card_template_sync_test.dart`。

## 3. 需要用户拍板

1. 2.2 的改名清单：全改，还是只改 `Picture→Media`、`MiscInfo→Source` 两个最膈应的？
2. 是否接受「稳定键 + 显示名」拆分（旧数据零迁移的前提）；不接受则只能走「新建字段 + 搬值 + 软删旧字段」，
   同步成本高很多，不建议。
3. Lapis 内置类型是否也改名：建议不改（官方兼容件）。
4. 画面默认模式：视频 clip、galgame animated、漫画 / 书 image，是否合意。

## 4. 实现分步（拍板后）

1. 内置字段定义拆「键 / 显示名」+ 导出 / 回导按 ankiNum 匹配 + 测试（含固定输入旧卡回归）。
2. `{card-media}` 占位符 + 制卡来源默认模式设置 + 旧别名兼容。
3. 模板 `.fc-media` 与 `<video>` 行为；Anki / AnkiDroid / AnkiMobile 实测 `<video>`。
4. 15 语种文案走 `i18n_sync`。

## 5. 风险

- fieldId 派生规则是最大雷区，步骤 1 必须先落地并带回归测试，再动别的。
- Anki 端对 `<video>` 的支持因客户端而异，必须实测后才允许默认 clip 写进 Anki 目标。

## 6. 实现记录（2026-10-29）

用户拍板：2.2 改名清单**全部采纳**；Lapis 内置类型不改；**字段名就是键名（不另设显示名），旧名作别名兼容**。
与第 2.1 节「稳定键 + 显示名」的差别：不再有第二个名字——Anki 里看到的、模板里写的、制卡映射的键都是新名；
旧名只在「读入口」和「ID 派生」两处作别名存在。

- **单一真相**：`packages/fushi_anki/lib/src/fushi_card_fields.dart`（`FushiCardFields`）：新名常量、`legacyNames`
  （新→旧）、`canonical` / `canonicalizeFields` / `value` / `alignToFields` / `legacyNameOf`。
- **fieldId 不变**：内置字段的 ID / ankiNum 按**旧名**派生（`srsBuiltinFieldSeed`，仅 `fushi_card`），旧卡的字段值、
  同步日志、词状态零迁移；内置笔记类型本来就是「代码默认 + 修改记录」物化，名字自动跟随新名。
  回归：`srs_builtin_fushi_card_test.dart`（新旧名都算出同一个 fieldId；Lapis 的 ID 不受影响）。
- **旧名兼容入口**：
  - 制卡到 Anki：`fieldsForNoteType` / `fieldMappingsAfterFetch` / AnkiDroid 取值前先 `alignToFields`——Anki 里已导出的
    Fushi 卡片还是旧名（或映射偏好存的是旧名）都对得上，用户映射不丢；
  - Lapis → Fushi 卡片迁移计划：`srsLapisFieldSlot` 把旧名 / Lapis 内置字段落到新名槽位；
  - 导入的 Fushi 导出包（非内置）：`srsGuessFieldMapping` 与 Rust `effective_frequency_field` 认 `FrequencyRank`；
  - 字段目录 / 人话名 / 说明：`srsKnownField*` 经 `legacyNameOf` 查表。
- **未做（按需再开）**：
  - `{card-media}` 占位符：`{card-image}` 本来就按制卡模式产出静态图 / GIF / 视频片段，新增占位符要同时改
    设置页、映射偏好、导出包、12 处接线，且是持久化名；收益只是名字，暂缓。
  - 各语种里 `srs_field_info_picture_*` 一类人话文案仍写「图片」，等 `Media` 的统一措辞定下来再批量改。
  - AnkiDroid / AnkiMobile 对字段内 `<video>` 的实测仍未做。

### 6.1 画面默认模式与 `.fc-media`（2026-10-29 追加）

- **按来源的画面模式设置早就存在**，不需要新建：视频 `video_mining_image_mode`、galgame `gal_mining_image_mode`
  各存一份，设置页各有一行（`anki_settings_page.dart`、控制通道 `ctl_settings_body_anki.dart`）。漫画 / 书只有
  静态裁图，没有模式可选。
- 本次改的是**未设置时的默认**：视频仍是视频片段，**galgame 改为动图（gif）**——
  `galMiningImageMode` 对没显式设过的值取 `VideoMiningImageMode.gif`（`fromWireName(fallback:)`）。
  显式选过的值（含显式视频片段）不受影响；老用户里没动过 galgame 这项的，下次制卡起出动图而不是片段。
  这改变了所有者 2026-10-01「老用户也用片段」时 galgame 的默认，是用户 2026-10-29 明确要求的。
- 模板类名：`.fc-picture → .fc-media`、`.fc-def-picture → .fc-def-media`（模板源、样式、脚本选择器、
  生成文件同步）。宿主注入的 `fushi-srs-hide-picture` 类名是宿主契约，未动。
