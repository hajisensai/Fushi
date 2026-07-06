## BUG-564 · iOS/Anki 制卡外字 SVG 偶发读不到（词典媒体缓存名使用 String.hashCode）

- **报告**：2026-07-06（用户：「拉取一下develop的分支。然后看看ios端制卡制卡是图片还是gif，而且看看为什么有时候svg会炸了」）。
- **真实性**：✅ 真 bug（结构性）。真实链路是 popup.js 生成 `<img src="hoshi_dict_N.svg">` 占位符和 `dictionaryMedia` 负载 → `writeDictionaryMediaCache` 把 `HoshiDicts.getMediaFile(dict, path)` 落到 `Directory.systemTemp/anki-media` → AnkiMobile/AnkiDroid/AnkiConnect 用同一个 `ankiDictionaryMediaCacheFilename(path)` 读缓存并替换占位符。根因在 `packages/hibiki_anki/lib/src/anki_models.dart:619`：缓存文件名使用 `path.hashCode`。`String.hashCode` 不是持久文件名契约，跨运行时/平台/编译模式不保证稳定；因此同一 SVG path 在 writer/reader 发生进程边界、热重启、平台差异或缓存复用时会偶发对不上，表现为 SVG 外字留作坏图/未替换占位符。
- **[x] ① 已修复** — `ankiDictionaryMediaCacheFilename` 改成 `hibiki_dict_<sha1(utf8(path))>.<ext>`，保留无扩展名回退 `bin`。writer 和三个 backend 仍共用同一个 helper，修的是命名真源，不在各端加特例。提交哈希：40ae1ae72。
- **[x] ② 已加自动化测试** — `hibiki/test/anki/anki_dict_media_cache_test.dart` 和 `packages/hibiki_anki/test/media_filename_guard_test.dart` 锁定 `gaiji/bs一.svg` / 无扩展名路径的稳定 SHA-1 文件名，并明确禁止退回 `String.hashCode` 语义。
- **备注**：iOS 视频/沉浸制卡封面路径当前优先生成 GIF（`immersion_clip.gif` / `netflix_clip.gif`）；GIF 抽取失败、无 cue 或 Netflix capture 缺 GIF 时才降级 JPG 截图。Hoshi-Reader Mac 参考实现视频制卡是 PNG 截图 + M4A 音频，不是 GIF。
