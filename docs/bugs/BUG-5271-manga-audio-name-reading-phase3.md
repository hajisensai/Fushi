## BUG-5271 · 漫画有声人名读法第三期：AI 抄原页振假名 / 查官方资料记出处；同一写法按角色区分读音
- **报告**：2026-11-23（拍板台 `TW9ete_FHX`「漫画有声增加人名读法校对步骤」，维护者「做」，建议分期；第一、二期已随 PR #4122 合入 develop `f4d9ebf142`，本条登记剩下的部分）
- **真实性**：✅ 功能缺口（已拍板「做」的剩余部分）。已有：系列用词替换的「人名」类别只改朗读、读法留空即待复核不生效、单字简称只在称呼后缀前命中、从角色表按规范名 + 别名补待复核条目（`packages/fushi_engine/lib/tts/cast/cast_text_substitution.dart` `pendingCastNameEntries` :192），制作台「读法变了的台词」一键重生成。缺：
  1. **读法来源仍全靠手填**：角色表推断（`packages/fushi_engine/lib/tts/manga_audio/manga_audio_annotate.dart` `buildMangaRosterUserPrompt` :140 / `parseMangaRosterReply` :205）只出名字和别名，不让模型看角色首次出场 / 自我介绍的页图抄原页振假名、记页码；原页没注音时也没有「按作品名 + 角色名查官方角色资料并记出处」的步骤。原文要求：找不到明确出处或多来源冲突时留空待复核，AI 结果默认待复核、不自动生效。
  2. **同一写法不能按角色给不同读音**：`validateCastSubstitutions`（:118）把同原文的第二条判 `duplicateSource` 直接丢弃，`CastTextSubstitution.character` 只用于分组展示与去重（:70 注释），`_applySubstitutions`（:149）匹配时不看说话人 / 被称呼的角色，所以两个角色同名不同读（或同一简称指不同人）时只能二选一。
- **[ ] ① 部分修复**（缺口 1 已做，分支 `claude/dec-tw9ete-fhx-p3`）：
  - 条目加出处 `CastNameEvidence`（页面注音：卷名 + 页码，AI 抄录另标；官方资料：URL），`suggestedReading` 只在所有出处读法一致时给建议，冲突留待复核；读法仍留空、不生效，用户在用词替换页点「采用」才填进读法（`packages/fushi_engine/lib/tts/cast/cast_text_substitution.dart`）。
  - 「查找人名读法」（`packages/fushi_engine/lib/tts/manga_audio/manga_name_readings.dart` `MangaNameReadingFinder`）：先本地扫系列各卷 OCR 判出的注音块恰好注在名字上的地方（不靠 AI，不联网）；剩下的名字带本卷首次出现页的页图 + 可选联网搜索摘要问 AI，回复里页码必须是发过的页、URL 必须是发过的结果，否则整条丢弃（凭汉字 / 记忆猜的读法进不来）。
  - 角色表推断之后自动做一遍本卷页面注音收集（`ai_manga_audio_assistant.dart` `_collectNameRuby`），有出处的名字补成待复核条目。
  - **缺口 2（同一写法按角色区分读音）仍未做**：需要先定「按什么判定指的是哪个角色」（说话人？被称呼者？同页出场？），定口径前不动 `validateCastSubstitutions` 的唯一键。
- **[ ] ② 部分加测试** — 已加 `packages/fushi_engine/test/tts/manga_audio/manga_name_readings_test.dart`（出处 JSON 往返、建议 / 冲突、待复核不生效、页面注音只认恰好注在写法上的、AI 回复页码 / URL 校验、AI 失败保留页面注音结果）与 `fushi/test/media/audiobook/tts/cast/cast_substitutions_page_test.dart`「查找人名读法 → 采用」；缺口 2 的测试随缺口 2 补。
- **备注**：新 key 的 zh-HK 为英文不算本条剩余项——仓库里 zh-HK 一半 key（7192 / 14678 个字符串值）都与英文相同，属整体翻译欠账。
