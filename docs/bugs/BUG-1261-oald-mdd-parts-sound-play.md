## BUG-1261 · MDX 分卷 MDD 未挂载 + 词典内 sound:// 发音点击无反应（OALD）
- **报告**：2026-07-31（用户：导入「OALD 2024.09」（OALDPE：oaldpe.mdx + oaldpe.mdd + oaldpe.1/2/3.mdd）后，点词典释义里自带的发音按钮没反应）
- **真实性**：✅ 真 bug，两层根因叠加（任一层都足以让发音完全无反应）：
  1. **分卷 MDD 根本没导入**：`native/hoshidicts/hoshidicts_src/importer.cpp`（原 1027-1031 行）只做 `Foo.mdx → Foo.mdd` 单文件挂载；MDict 惯例的编号分卷 `Foo.1.mdd / Foo.2.mdd / ...` 完全被忽略。OALDPE 的全部发音 mp3（`oaldpe.1.mdd` 16 万个单词音 + `oaldpe.3.mdd` 11 万个例句音，实测均为 .mp3）和例句配图（`oaldpe.2.mdd`）都在分卷里 → `getMediaFile` 必 miss。zip 导入路径（原 1074 行）同样只放行 `fstem == stem` 的 `.mdd`。
  2. **sound:// 播放从未实现**：`hibiki/assets/popup/popup.js` `handleGlossaryAnchorClick`（原 4317-4320 行）把 `sound://` 点击 preventDefault 后**故意丢弃**（注释「播放另属后续能力」，BUG-767 时留下的缺口）；四个弹窗表面注册的自定义 scheme 只有 `image`/`dictmedia`，无任何取音频播放的通路。
- **[x] ① 已修复** — 提交 `8a2b0753c`：
  - C++：`import_mdd_into` 改为多文件单索引合并写（逐分卷解析、峰值内存仍为单分卷；全部记录进**一个** `media.bin`/`media.idx`，查询侧二分不变）；新增 `collect_sibling_mdd_paths`（主 `.mdd` + 顺序编号 `.N.mdd`，断号即止）；zip 路径放行 `stem.N.mdd`。顺带把 `append_media_record` 的写偏移累计从 u32 加宽到 u64（磁盘格式本就是 u64 偏移；OALD 解压后 ~3.7GB 已贴近 4GB 回绕悬崖，多分卷合并必须消掉这个静默越界边界）。
  - JS：`handleGlossaryAnchorClick` 的 `sound://` 分支剥前缀后复用 `rewriteDictionaryMediaPath`（与 `<img>`/gaiji 同一词典媒体字节通道：app 内 → `image://` scheme，四个宿主表面均已注册且 WebView2 过滤器为 `*`+CONTEXT_ALL；浏览器扩展 → 带 token 的 `/api/media/dictionary`），经 `playWordAudio` 播放（与单词 ♪ 同音量/interrupt 语义）。三份 popup.js 镜像经 sync-mirrors.mjs 同步。Dart/native 零改动（mp3 MIME 已在 `mimeTypeForFilePath`，autoplay 已放开）。
  - Dart 导入层核查：目录导入把 .mdx **原始路径**直接交 native（`dictionary_import_manager.dart:343-347`），分卷躺在同目录，无需改动。
- **[x] ② 已加自动化测试** — 同提交 `8a2b0753c`：
  - `native/hoshidicts/tests/mdd_media_import_test.cpp`：M.mdd + M.1.mdd + M.2.mdd 三分卷导入，断言三个 key（含 mp3）全部可取（已变异实测：砍掉分卷发现逻辑 → 两个分卷 blob 取不到，测试红）。
  - `test/js/dict_glossary_crossref_link.test.mjs`：`sound://` 点击（在 `data-dictionary` 容器内）断言阻止导航、不查词、且以精确 `image://?dictionary=...&path=...` URL 触发一次播放；无词典容器时不播不崩。
- **备注**：修复要生效需**删除并重新导入** OALD（分卷资源是导入期写入 media.bin 的）。移动端单文件选择器（SAF）只拷 .mdx 本体、丢所有 sibling（主 .mdd 同样受影响）是既有限制，不在本轮范围；文件夹导入路径无此问题。`.spx`（老 OALD Speex）仍不可解码——OALDPE 2024.09 实测全 mp3，不涉及。
