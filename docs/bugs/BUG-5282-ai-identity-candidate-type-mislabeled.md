## BUG-5282 · AI 识别作品时候选类型被标成本地搜索类型，正确候选被压低置信度不采用
- **报告**：2026-11-23（用户：待确认作品为什么 AI 不自动处理）
- **真实性**：✅ 真 bug。运行记录 `ai:declined confidence=0.75`（BOCCHI THE ROCK! 6 - 03）：AI 选对了 TV 第 1 期，理由写「候补の種別が映画と表示されている点が不確定要素」。根因 `video_source_scrape_coordinator.dart` `_aiQuery` 用 `option.lookup.mediaKind` 当候选类型，而 AniDB 标题目录命中（`_catalogWork`）的 kind 就是本地这次的搜索类型（单文件 → movie），完整资料里 OVA / Web / TV Special 也回填本地形态（`_mediaKindForAnime`）——模型看到的「类型」是我们自己猜的。另：系统提示要求「标题、类型、年份、季号全一致才 ≥0.9，否则 <0.85」，BD 分卷（vol.6、上巻/下巻、Disc N）只含部分集数的情形没有说明，同类判定（魔女の旅々 上巻 0.80、ユーフォ 特別編 0.83）全卡在门槛下。
- **[x] ① 已修复** — `AiVideoIdentityCandidate.mediaKind` 改可空；协调器 `_aiCandidateKind`：AniDB 只认原始 `type` 的 Movie / TV Series，目录命中与其它类型给 null（JSON 里不带 mediaKind），MAL / TMDB 照旧。系统提示补两条：BD/DVD 分卷与部分集数不算矛盾、只有本地明显多于候选集数才算；候选缺字段是未知不是不符；≥0.9 的条件改为「标题明确同一作品且已知线索无矛盾」。自动采用门槛 0.85 不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_source_scrape_coordinator_test.dart`「高置信判定…」断言目录候选的 mediaKind 为 null、JSON 不带该字段。
- **备注**：提示词措辞的效果只能靠真实模型观察，单测只守住传给模型的数据。
