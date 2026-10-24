## BUG-3663 · 「选择音频源」菜单里本地音频库（android.db）只露出一个子来源
- **报告**：2026-10-23（用户：「android.db好像长按也没法选取音频来源」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/word_audio_resolver.dart` `_listLocal`：每个本地库只调 `_resolveLocalAt` → `LocalAudioDb.queryMeta`（`fushi/lib/src/utils/misc/local_audio_db.dart`，按子来源优先级只挑 **一条**），Android 原生 `TtsChannelHandler.handleQueryLocalAudio` 同样只回一条。Yomitan 本地音频库里 forvo / nhk16 / jpod 等子来源同时有这个词时，长按 / 右键菜单永远只有一项，无从选择。
- **[x] ① 已修复** — 新增 `LocalAudioDb.queryMetaAll`（同一 reading 精确优先 / 回落与子来源过滤，按优先级稳定排序，首项 = `queryMeta`）、`TtsChannel.queryLocalAudioAll`（桌面 Isolate 查询；Android 走 `queryLocalAudio` + `all: true`，Java `handleQueryLocalAudioAll` / `sortByOrder`）、`WordAudioResolver.queryLocalAudioListByDbIndex`；菜单逐子来源列出，变体名 = 子来源名（同子来源多条带目录名，如 `forvo · 发音人`）。单击 ♪ 的默认源不变。
- **[x] ② 已加自动化测试** — `fushi/test/utils/local_audio_db_test.dart`「queryMetaAll lists every enabled sub-source」、`fushi/test/utils/misc/word_audio_resolver_list_test.dart`「a local db lists every sub-source hit」。
- **备注**：桌面上菜单靠**右键**（或 Shift+F10）打开，鼠标长按不触发；触屏长按 450 ms。
