## BUG-1700 · 自动下字幕的默认语言是「不限」，实际拿到的语言随缘，不跟视频自身语言
- **报告**：2026-08-17（用户：「默认下载视频语言的字幕」）
- **真实性**：✅ 真问题。`jimakuDefaultLanguage` 缺省 `''`，UI 标签写「全部」，语义是**不表态**：
  - 下载流水线：`preferredSubtitleLanguages` 变成空 list → `VideoSubtitleSearchRequest.languages` 为空 → provider 不按语言过滤 → 最终 `result.items.first`（按 provider 优先级 + 下载量排）**语言随缘**；
  - 番剧下载反查：`plan.jimakuLanguage` 为 null → `jimakuLanguageRank` 退回它自己的 ja>zh>en>ko 默认权重。对日语番碰巧对，对**韩剧就是错的**。

  对一个沉浸学习 app，「视频是什么语言就先要什么语言的字幕」几乎总是用户想要的那条，而这从来不是默认。
- **[x] ① 已修复**
  - 新增 `fushi/lib/src/media/video/subtitle/subtitle_language_preference.dart`（纯函数）：
    - `resolveSubtitleDownloadLanguage`——优先级 **用户显式选的字幕语言 > 视频内容语言 > null**。内容那一半**直接委托** `resolveContentLanguage`（全仓内容语言唯一入口：资源手动指定 `VideoBooks.language` > 内容自带元数据 > 全局默认），**不另造一条链**：字体链和字幕语言链各写一遍，早晚出现「字体按日文渲染、字幕却下了中文」。
    - `normalizeSubtitleLanguageCode`——BCP-47 / ISO 639-2 / 俗写归一（`ja-JP`/`jpn`/`jp`→`ja`，`chs`/`cht`/`yue`→`zh`），认不出**原样返回主标签**而不是丢弃。
    - `rankByPreferredLanguage`——**稳定**重排，首选语言在前。
  - 「视频语言」的一手来源：`video_duration_probe.dart` 扩成 `probeVideoFacts`，**同一次 ffprobe** 拿时长 + 音轨 language tag（`format=duration:stream=...:stream_tags=language`）。只认音轨（字幕轨的 language 不能冒充视频语言），`und` 视同未标注跳过。
  - 接入四处：下载流水线 `_selectVerifiedSubtitle`、刮削后补字幕 `VideoSubtitleBackfillService`、番剧下载 `JimakuPlanSubtitleResolver`、`scrapedSubtitleTargets`（带上 `VideoBooks.language` 与刮削 `originalLanguage`）。
  - 设置项 `''` 的标签从「全部」改成**「跟随视频语言」**（新 key `video_jimaku_language_follow_video`；浏览用对话框里的「全部」语义仍正确，**不复用同一个 key**——同值不同义就该两个标签），hint 同步改写。

  🔴 **关键设计：是排序，不是过滤。** 按语言硬过滤会把「只有英文字幕的日语番」从**有字幕**倒退成**没字幕**——拿一个改进换一个回归。硬过滤只留给用户在设置里显式指定的语言（那是他自己说的，进 `request.languages`）。
  🔴 **语言未知就不表态**（返回 null，行为与改动前逐字节一致）。**尤其不许硬编码日语**——本 app 没有全局学习语言，见 `reference_no_global_target_language_do_not_assume_japanese`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_language_preference_test.dart`（17 条）：归一各形态、四档优先级、全空返回 null、排序不丢候选、归一后比较、稳定性、ffprobe 双事实解析（只认音轨 / `und` 跳过 / 一半缺失不作废）。**已做变异实测**：把 `rankByPreferredLanguage` 的返回改成只留匹配项（= 退化成硬过滤），套件 PASSED→FAILED（2 处断言捕获），还原后 sha256 逐字节一致。
- **备注**：改标签时撞出一条真回归——`video_external_provider_settings_section` 的语言下拉在 360px 紧凑布局横向溢出。根因不是中文文案长，是那个 `DropdownButtonFormField` 缺 `isExpanded: true`（按内容固有宽度排版），此前选项全是「日本語」「中文」这类两三字标签才没暴露；17 份 i18n 里未翻译的落英文原串 `Follow video language` 更长。**修的是约束（isExpanded + 逐项 ellipsis），不是文案。**
