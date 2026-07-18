## BUG-897 · Anki 外字(gaiji)媒体缓存键漏词典名 → 跨词典串味
- **报告**：2026-07-19（守卫审计批次）
- **真实性**：✅ 真 bug（结构性，沿真实读写链路定位）。
- **[x] ① 已修复** — 缓存键改为对 `<dict> <path>`（词典名 + NUL 分隔 + 相对路径）求 sha1；函数签名 `ankiDictionaryMediaCacheFilename(String dictionary, String path)`，四处读写点同步补词典名。
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/media_filename_guard_test.dart` + `hibiki/test/anki/anki_dict_media_cache_test.dart`（同 path 不同词典 → 文件名不同；同 dict 同 path → 稳定一致；NUL 分隔消歧义）。
- **备注**：与 BUG-640（把 hashCode 换成 sha1）兼容——继续用 sha1，只是把词典名纳入 hash 输入。真机复测原始失败路径待做。

### 现象
两本词典含**同一相对路径**的外字（如都叫 `gaiji/参照.svg`，但字节不同）时，制卡把外字嵌进卡片会串味：后制卡的词典命中前者缓存的图片。表现为某个义项的外字 SVG 显示成别的词典的字形。

### 根因
制卡词典媒体（gaiji 外字、词典内嵌图）落盘缓存的文件名由 `ankiDictionaryMediaCacheFilename(String path)` 生成（`packages/hibiki_anki/lib/src/anki_models.dart:641`，BUG-640 后为 `hibiki_dict_<sha1(path)>.<ext>`）。**只对相对 path 求 sha1，不含词典名**——两本词典的同名相对路径算出同一文件名。

writer 幂等（`dictionary_webview_media.dart:54` `if (file.existsSync()) continue;`）：第一本词典先把字节写进 `hibiki_dict_<sha1(path)>.ext`；第二本词典同名 path 命中同一文件、因已存在被跳过 → 缓存里始终是第一本的字节。三个读侧 repo 再按同名读出、storeMediaFile → 第二本的卡片嵌入第一本的外字（跨词典碰撞/串味）。

真实读写点（改前均只传 `path`，丢弃已在手的词典名）：
- 写侧 `hibiki/lib/src/pages/implementations/dictionary_webview_media.dart:53`（循环里 `final String dict = raw['dictionary']…:49` 已有词典名，构键时被丢弃）。
- 读侧 `hibiki/lib/src/anki/ankimobile_repository.dart:424`（`media.dictionary` 未用）。
- 读侧 `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:990`（`media.dictionary` 未用）。
- 读侧 `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:706`（`media.dictionary` 未用）。

### 修复
把缓存键的 hash 输入从 `path` 改成 `<dict> <path>`（`utf8.encode('$dictionary $path')`，NUL 分隔避免 `('ab','c')` 与 `('a','bc')` 拼接歧义），消除跨词典碰撞：

- `anki_models.dart`：函数签名改 `ankiDictionaryMediaCacheFilename(String dictionary, String path)`，摘要 `hibiki_dict_<sha1(dictionary NUL path)>.<ext>`；沿用 sha1（BUG-640）与无扩展名回退 `bin`（HBK-AUDIT-062）。改签名让编译器强制所有调用点补词典名，不会漏改。
- 四处读写点同步改：写侧传循环里的 `dict`；三个读侧 repo 传各自 `DictionaryMedia` 的 `media.dictionary`。writer/reader 仍共用同一 helper（防漂移）。

同一本词典、同一 path 的既有卡片路径行为不变（哈希只是多前缀了词典名，仍稳定一致）。
