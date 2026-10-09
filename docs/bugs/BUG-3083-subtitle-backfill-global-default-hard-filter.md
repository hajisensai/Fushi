## BUG-3083 · 补字幕在无作品语言证据时把全局默认内容语言当硬过滤，英语片的英文字幕被拒
- **报告**：2026-10-09（#2007 合入后的审查）
- **真实性**：✅ 真 bug。`VideoSubtitleBackfillService.backfill`（`fushi/lib/src/media/video/subtitle/video_subtitle_backfill.dart:218-225`，修前行号）把 `defaultContentLanguage`（设置·外观·排版里的全局默认内容语言）当作 `globalDefaultContentLanguage` 传给 `resolveSubtitleDownloadLanguage`，得到的 `preferred` 又直接用作硬过滤，候选要过两关：
  - 下载前：`_rejectBeforeDownload`（`:341`）拒掉声明语言不同的候选；
  - 下载后：`_rejectDownloadedLanguage`（`:356-361`）按正文再拒一次。

  视频没有刮削原语言、音轨也没有语言 tag 时，`preferred` 会退到全局默认（例如 ja）。这时一部英语片的英文字幕两关都过不去。全局偏好并不是这部作品的语言证据。
- **[x] ① 已修复**（`f59868a07a`）— 把「硬条件」和「排序偏好」拆成两个值：
  - `preferred`（硬过滤，`video_subtitle_backfill.dart:222`）只由这部作品自己的证据解析：显式字幕语言 / 手动内容语言 / 刮削原语言 / 音轨 tag，不再传入全局默认；
  - `ranking`（`:229`）= `preferred ??` 全局默认，只交给 `rankByPreferredLanguage`（`:255`）排序。

  有作品证据时行为不变，BUG-3069 的硬拒保留。没有作品证据时，全局默认只决定先试哪一条，不拒任何语言。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/video_subtitle_backfill_work_identity_test.dart` 的 `BUG-3083` 组，用真实 Jimaku provider + MockClient，共 3 条：
  - 没有语言证据、全局默认为 ja：英文字幕照常装上；
  - 同时有 ja / en 候选：ja 排在前面先装；
  - 对照组，原语言为 ja：英文仍被硬拒。

  变异实测：回退修复后，第一条变红。
- **备注**：用户在设置里显式选的字幕语言（`preferredLanguages`）仍然是硬条件，因为那是用户对「要什么字幕」直接表的态。
