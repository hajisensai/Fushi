# 复习历史捐赠（给 anki-rwkv）

所有者 2026-11-26 拍板；上游作者（JSchoreels，anki-rwkv，Discord @SoundJona）已书面同意格式与用途。
上游页面：https://jschoreels.github.io/anki-rwkv/donations.html

## 目标

复习量够的用户在 SRS 首页看到一条可关闭的横幅，自愿把复习历史捐给 anki-rwkv 训练调度模型。
文件先传到我们自己的 `rank.fushi.moe`（R2），所有者每月生成一个私有批次链接交给作者；不走 Dropbox。

## 已拍板的取舍

| 项 | 决定 |
|---|---|
| 门槛 | 当前 profile 评分复习 ≥ **1000** 次，且最早一次复习距今 ≥ **14** 天 |
| 平台 | iOS 不加（判据写进 `fushi/lib/src/models/store_compliance.dart`：`srsDonationAvailableOn({required bool isIOS}) => !isIOS`，消费端不写 `Platform.isIOS`） |
| 共享范围 | Fushi + anki-rwkv，可共享给 Open Spaced Repetition 成员仅作研究，永不公开 |
| 卡面内容 | 只保留词头 + 读音（规则见下），其余全部清空；用户可在预览里逐词排除或整体关掉 |
| 投递 | 一个用户一个文件，同一捐赠 ID 重传覆盖旧文件；每月一个私有批次链接 |
| 撤回 | 用户随时在设置里撤回：我们删文件，并把 ID 记进下一批的撤回清单交给作者删除 |
| 里程碑 | 不同捐赠者数第一次达到 30 时通知所有者（Discord webhook，见服务端） |

同意文案（英文原文，作者给定；各语言翻译保持同义）：

> Your review history will be used to train spaced-repetition models published under the MIT license. The files are kept by Fushi and anki-rwkv and may be shared with members of the Open Spaced Repetition project for research only; they are never published or shared outside it.

## 捐赠身份

- `donorId = hex(sha256("fushi-srs-donation-id:" + profileUid))` 取前 32 个十六进制字符。
- `donorKey = hex(sha256("fushi-srs-donation-key:" + profileUid))`（64 个十六进制字符），作上传 / 查询 / 撤回的 Bearer 凭据；服务端只存 `sha256(donorKey)`。
- 同一 profile 在任何设备上算出同一对，重传自然覆盖。已知取舍：拿到该用户带 fushi-ext 的导出包（含 profileUid）的人能替他覆盖 / 撤回捐赠，危害只限于此，接受。

## 捐赠包格式（`packages/fushi_engine/lib/srs/apkg/srs_donation_export.dart`）

复用现有 Anki 导出器（`srs_apkg_export.dart` 的 `_Exporter`，加一个「脱敏策略」参数，不复制一份导出器）。产物是 Anki 兼容 `.apkg`（zip：`collection.anki21` schema-11 + `media` = `{}`），不带 fushi-ext、不带媒体。与普通导出的区别：

1. **revlog**：只导 `SrsLogKind.review`（手动改期 / 重排丢弃）；`time` 列写真实 `durationMs`，**不做 60 s 截断**；`id` 仍是原始 `occurredAt`（撞号 +1 ms 规则不变），从 Anki 导入的日志保留原 Anki 时间戳，作者那边靠 revlog id 去重。
2. **来源标记**：集合里多一张表 `fushi_revlog_origin(id INTEGER PRIMARY KEY, origin TEXT NOT NULL)`，每条 revlog 一行，`origin` 取 `SrsReviewLog.origin`（`fushi` / `anki` / 其他原值）。
3. **元信息表** `fushi_donation_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)`：`format`=`fushi-srs-donation`、`version`=`1`、`donor_id`、`exported_at`（ms）、`app_version`、`scheduler`=`fushi-fsrs`、`utc_offset_min`、`rollover_hour`。时区与「次日开始」小时同时照常写在 `col.conf`（`rollover` / `creationOffset` / `localOffset`，现有导出已写）。
4. **脱敏**：
   - 牌组名 → `Deck <n>`、牌组预设名 → `Preset <n>`、笔记类型名 → `NoteType <n>`、字段名 → `Headword` / `Reading` / `Field <n>`；层级关系与 id 不变（`cards.nid` / `cards.did`、牌组的预设 id 照常）。
   - 标签全部清空；note `guid` 换成 `sha256(guid)` 前 10 个字符（保留「同一笔记」关系，不暴露共享牌组来源）。
   - 字段值除词头 / 读音外全部写空串；`sfld` / `csum` 按保留后的首字段重算。
5. **词头 / 读音保留规则**（只有 `includeWords == true` 且该笔记不在排除集合里时）：
   - 内置类型：Lapis 的 `Expression` / `ExpressionReading`，Fushi 卡片的 `FushiCardFields.term` / `termReading`（字段 id 用 `srs_builtin.dart` 的现成函数取）。
   - 其他（含从 Anki 导入的自定义类型）：字段名（去空格、大小写不敏感）命中白名单才考虑。词头白名单：`expression, word, vocab, vocabulary, kanji, term, headword, japanese, 単語, 語彙, 言葉, 漢字, 表記`；读音白名单：`reading, kana, hiragana, expressionreading, wordreading, vocabreading, vocabkana, 読み, 読み方, かな, 仮名`。每类取第一个命中的字段。
   - 值校验：去 HTML（`ankiStripHtml`）并 trim 后，词头 1–15 个字符且全为平假名 / 片假名 / 汉字 / `ー々〆ヶ`，读音同样长度且只含假名与 `ー`；任何空格、标点、拉丁字母、数字、括号（如 `漢字[かんじ]`）都不通过 → 该字段清空。读音单独不通过不影响词头。
   - 同一套规则只写一处（纯函数，带单测）：`srsDonationHeadwordOf(...)`，预览与导出共用。
6. **范围**：当前 profile 全部牌组；只导出至少有一条 review 日志的卡所属的笔记（没复习过的新卡不进包）。

公开 API（Dart，类型签名固定，客户端照此调用）：

```dart
class SrsDonationWord { final String noteId; final String headword; final String? reading; }
class SrsDonationPreview {
  final int reviewCount;        // 将进包的 revlog 条数
  final int cardCount;
  final int noteCount;
  final DateTime? firstReviewAt;
  final List<SrsDonationWord> words; // 会保留词头的笔记（按词头排序）
}
Future<SrsDonationPreview> previewSrsDonation({required SrsDbStore store});
Future<void> exportSrsDonationFile({
  required SrsDbStore store,
  required File file,
  required String donorId,
  required String appVersion,
  bool includeWords = true,
  Set<String> excludedNoteIds = const <String>{},
});
({String donorId, String donorKey}) srsDonationIdentity(String profileUid);
```

## 服务端（`services/leaderboard/src/srs_donations.js`）

存储：R2 `MEDIA` 桶键 `srs-donations/<donorId>.apkg`；D1 迁移 `0027_srs_donations.sql`：
- `srs_donations(donor_id TEXT PRIMARY KEY, key_hash TEXT NOT NULL, bytes INTEGER, reviews INTEGER, cards INTEGER, app_version TEXT, created_at INTEGER, updated_at INTEGER)`
- `srs_donation_withdrawals(donor_id TEXT PRIMARY KEY, withdrawn_at INTEGER NOT NULL, reported_batch TEXT NULL)`
- `srs_donation_batches(token TEXT PRIMARY KEY, created_at INTEGER, expires_at INTEGER, donors_json TEXT, withdrawn_json TEXT)`
- `srs_donation_milestones(name TEXT PRIMARY KEY, reached_at INTEGER)`

接口：
- `PUT /v1/srs-donations/:donorId`，`Authorization: Bearer <donorKey>`，body = apkg 原始字节（`application/octet-stream`，流式写 R2），头 `x-donation-reviews` / `x-donation-cards` / `x-donation-app-version`。校验：donorId 32 位小写 hex、key 64 位 hex、zip 魔数 `PK\x03\x04`、大小 ≤ 64 MiB；已有记录时 key_hash 必须一致，否则 403。按 donorId 每小时 2 次、按 IP 日字节额度（沿用大附件池 / `budget.js` 口径）。曾撤回的 ID 重新捐赠：删掉撤回记录中尚未 `reported_batch` 的那条，已报告过的保留（作者那边已删，新文件照常进下一批）。→ `200 {donated: true, updatedAt}`。
- `GET /v1/srs-donations/:donorId`（Bearer）→ `200 {donated, reviews, cards, updatedAt}`，无记录 `{donated: false}`。
- `DELETE /v1/srs-donations/:donorId`（Bearer）→ 删 R2 + 行，写撤回记录 → `200 {donated: false}`。无记录也 200（幂等）。
- 管理（`checkBasicAuth`）：`POST /v1/admin/srs-donations/batch` 生成批次：快照当前全部捐赠与尚未报告的撤回 ID，随机 32 字节 token，30 天有效，返回 `{url}`；`GET /v1/admin/srs-donations` 列统计。
- 批次下载（凭 token，无其他认证）：`GET /d/srs-donations/<token>/` → 纯文本 / JSON 清单（每个文件的 donorId、reviews、bytes、下载 URL，加 `withdrawn` 列表）；`GET /d/srs-donations/<token>/<donorId>.apkg` → `Content-Disposition: attachment`、`application/octet-stream`；`GET /d/srs-donations/<token>/withdrawn.txt`。过期 404。快照之后被撤回的文件同样 404。
- 里程碑：每次成功上传后数 `srs_donations` 行数，第一次 ≥ 30 时写 `srs_donation_milestones('donors_30')` 并经 `ctx.waitUntil` POST 到 secret `DONATION_NOTIFY_WEBHOOK`（Discord webhook，`{content: "<DONATION_NOTIFY_MENTION> SRS review donations reached 30 donors (<reviews> reviews). Create a batch: POST /v1/admin/srs-donations/batch"}`）；secret 缺失只记日志不报错。
- 脚本 `services/leaderboard/scripts/srs_donation_batch.mjs`：调管理接口生成批次并打印链接。

## 客户端（`fushi/lib/src/srs/donation/`）

- 资格：`srsDonationAvailable`（store_compliance）且门槛满足且用户没选「不再提示」。
- 横幅：SRS 首页顶部一条卡片（公共组件、两套设计系统、带 `FushiStaggeredEntrance` / `FushiPressScale` 动效），按钮「了解并捐赠」「以后再说」（30 天后再出现）「不再提示」。已捐过：复习数比上次捐赠多 ≥ max(1000, 50%) 且距上次 ≥ 30 天时，横幅改为「更新捐赠」。
- 捐赠页（对话框或全屏页均可，走公共组件）：说明包含什么（复习时间、评分、用时、卡片 / 牌组结构、时区与次日开始时间、可选的词头 + 读音）与不包含什么（其他卡面文字、标签、牌组名、媒体）；同意文案；统计（复习数 / 卡片数）；「包含我学的单词」开关 + 词表预览（可搜索、逐词排除）；显示捐赠 ID 前 8 位；确认后后台 isolate 导出到临时文件 → PUT 上传（进度 + 失败重试按钮，不自动重试）→ 记偏好 `srs_donation_last_at` / `srs_donation_last_reviews` / 排除集合。
- 设置：SRS 设置页一项「复习历史捐赠」：状态（GET）、更新捐赠、撤回（确认框 → DELETE → 清偏好）。
- i18n 一律 `dart fushi/tool/i18n_sync.dart --add`，键前缀 `srs_donation_`。

## 给作者的数据说明

`docs/srs-donation-data-format.md`（英文）：逐表逐列说明包里有什么、与 Anki 原生的差异（Fushi FSRS 调度、`ease`/`ivl`/`factor` 的来源、`type` 映射、learning 步骤差异、duration 未截断、来源表、元信息表、时区字段、词头规则与空值含义、去重依据、撤回清单）。
