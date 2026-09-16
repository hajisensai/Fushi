## BUG-2573 · 浏览器扩展制卡单词音频丢失：data URI 的 base64 加号被归一化成空格
- **报告**：2026-09-15（用户：2.2.4 → 2.3.0 升级后，浏览器扩展制卡的 `ExpressionAudio` 字段没有单词音频）
- **真实性**：✅ 真 bug。
  - 触发提交：`3007ff272`（BUG-2189，制卡时把短命 token 换成自包含 `data:` URI）。
  - 根因：`packages/fushi_engine/lib/sync/immersion_mine_payload.dart:107`
    （`ImmersionMinePayload.fromJson` 对**每个** fields 值跑 `_normalizeIncomingText`，定义在 `:166`）。
    该函数为修「表单编码把空格弄成 `+`」而把孤立 `+` 还原成空格（`:184-192`），但**标准 base64
    字母表本身就含 `+`**——一个 4KB 单词音频的 base64 里通常有几十个孤立 `+`
    → `separatorPlusCount >= 2` → 全部替换成空格 → 字节被打坏。
  - 落卡侧后果：`packages/fushi_anki/lib/src/anki_models.dart:1354`
    `AnkiAudioRef.decodeDataUri` 的 `UriData.parse` 抛 `Invalid base64 data` → 返回 null
    → `ankiconnect_repository.dart:2211-2212` 返回 `AudioFetchOutcome.none()`
    → `:863` `processedAudio` 为空串 → 卡片 `ExpressionAudio` 没有音频。
  - 2.2.4 为什么不坏：那时 `fields.audio` 是 http token URL，token id 由
    `base64UrlEncode` 生成（字母表 `-` / `_`，**不含 `+`**），归一化对它无副作用。
- **[x] ① 已修复** — 提交 `e552b9701`：`_normalizeIncomingText` 对 `data:` 前缀的载荷整体
  原样透传（`immersion_mine_payload.dart:182`）。判据取 `data:` 形态而非白名单字段名——
  Anki 字段名是用户在模板里配的，硬编码 `audio` 认不全，而 `data:` 是载荷形态的可靠标识
  （外字图片 `dictionaryMedia` 同理受益）。普通文本字段的 `%XX` / `+`→空格 还原行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/immersion_mine_payload_test.dart`
  「BUG-2573：data: URI 载荷不被「加号→空格」归一化打坏」组，3 例：
  ① 含孤立 `+` 的 `data:` URI 原样透传（并自证构造里确有孤立 `+`，防止用例空心化）；
  ② 端到端：经 `fromJson` 后的 audio 用落卡侧真实 `AnkiAudioRef.decodeDataUri` 解码，
  字节与原始音频逐字节相等（直接钉死「不丢音频」这一用户可见结果）；
  ③ 回归：普通文本字段 `(明鏡+第三版)` / `C++ primer` 的既有还原行为不变。
- **备注**：
  - 复现实验（修复前）：4KB 音频 → base64 5464 字符、62 个孤立 `+`；归一化后
    `UriData.parse` 报 `FormatException: Invalid base64 data (at character 90)`；
    对照组（未归一化）解码出 4096 字节与原始完全一致。
  - 命中率接近 100%（base64 中 `+` 期望出现约 1/64/字符），所以表现为「每张卡都丢」，
    而不是偶发——与用户描述一致。
  - **为什么既有测试（BUG-2189 那 5 条）没抓到**：它们用的音频是 `[1,2,3]` / `[9,8,7]` /
    `[1]` 这种 1~3 字节，base64 是 `AQID` / `CAgH` / `AQ==`，**不含 `+`**，恰好绕开了
    归一化。真实单词音频是几 KB，才会触发。故补真实长度载荷的用例。
  - **反向验证**（确认测试非空心）：临时删掉 `startsWith('data:')` 那行后，新增用例
    立刻红（`+1 -2`），实际值可见 `FgX049LBsJ OfWxbSjko`（原应为 `...LBsJ+OfW...`），
    且 `AnkiAudioRef.decodeDataUri` 返回 `<null>`；恢复修复后 47/47 全绿。
  - 未改动落卡侧：`decodeDataUri` 的「坏载荷返回 null」是既有容错设计（BUG-1050），
    坏字节不可恢复，必须从源头修，不能在那里放宽。
