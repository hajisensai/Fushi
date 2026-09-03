## BUG-2059 · mdd 的 Encoding 为空时整个媒体库丢失
- **报告**：2026-09-03（用户：OALDPEX 词典包「js css 文件没有起效」）
- **真实性**：✅ 真 bug — `native/fushidicts/fushidicts_src/mdx/mdx_reader.cpp` 的 `parse_container()` 对空 `Encoding` 一律默认 `utf-8`：

  ```cpp
  result.encoding = get_attribute(header_text, "Encoding");
  if (result.encoding.empty()) result.encoding = "utf-8";
  ```

  但 **.mdd 的 key 是文件路径，按格式固定 UTF-16LE**，与 Encoding 属性无关；只有 .mdx 的正文才遵循 Encoding。MDTT 等写出的 .mdd 头正是空 Encoding：

  ```xml
  <Library_Data GeneratedByEngineVersion="2.0" Encrypted="No" Encoding="" Format=""
                CreationDate="2026-8-25" Description="A dictionary created with MDTT" … />
  ```

  于是 `is_utf16=false` → `null_term_bytes=1` → key block 扫描按单字节 NUL 在 UTF-16 数据里走，每个 key 的偏移逐个漂移，最终在读 record header 时抛 `mdx: record block info overflow`（`mdx_reader.cpp:464`）。

  **后果被日志掩盖**：`import_mdd_into` 把 mdd 失败当 best-effort，只打一条 `[fushidicts WARN] mdd parse failed (…), continuing without this part` 就继续，导入照样 `success=1`。所以用户看到的是「词典能查，但图片、发音、字体、脚本全没有」，而不是一条导入失败。

  用户那本 OALDPEX 的实测（导入 `1.zip`，293836 条）：
  - 修复前：无 `media.bin`，`get_media_file` 对 `scripts/oaldpex-jquery.js`、`fonts/Bookerly/Bookerly-Regular.ttf`、`images/ox3000_a1.svg` 全部 MISS。
  - 修复后：`media.bin` 10789863 字节 / `media.idx` 388 字节，上述三项分别 HIT 78748 / 313144 / 2892 字节。

  交叉验证：第三方解析器（python `mdict-utils`）能正常读出这个 .mdd 的 48 个条目，确认**文件是好的，是我们的解析器错了**。

- **[x] ① 已修复** — 按容器根元素自描述判定：`<Library_Data …>` 是 .mdd，空 Encoding 缺省为 `utf-16`；`<Dictionary …>`（.mdx）保持缺省 `utf-8`。显式声明了编码的 .mdd 仍按其声明处理，不改行为。

  零回归论证：改动只影响「根元素是 Library_Data 且 Encoding 为空」的文件，而这类文件在修复前 **100% 解析失败并被整个跳过**，因此任何变化都只可能是改善。

- **[x] ② 已加自动化测试** — `native/fushidicts/tests/mdd_empty_encoding_test.cpp`（ctest 用例 `mdd_empty_encoding_test`，已登记进 `native/fushidicts/tests/CMakeLists.txt`）。同时给 `mdx_fixture.hpp` 加了 `build_mdd_utf16_library_data()`：**既有的 `build_mdd_plain` 造的其实是 `<Dictionary … Encoding="UTF-8">` + UTF-8 keys，从来没覆盖过真实 .mdd 形状**，这正是这个 bug 能长期存活的原因。新用例断言真实形状的 .mdd 能挂载且三类资源（脚本/字体/图片）字节一致，并保留一段「显式声明 UTF-8 的 .mdd 不回归」。

  变异实测：把缺省改回 `utf-8` 后，该用例报 `mdd parse failed (mdx: record block info overflow)` + `media.bin absent — the .mdd was skipped entirely`（**与用户真实包的症状逐字相同**），其余 25 个 native 用例不受影响；还原后 26/26 绿，`mdx_reader.cpp` sha256 精确回到 `b20ade51…`。

- **备注**：
  - 顺带发现 `ImportResult::media_count` 对 mdx 路径**恒为 0** —— `import_mdd_into` 不回填该字段，只有 yomitan 的 `write_media` 累加。所以 BUG-927 那条「成功但计数全 0」的日志诊断对 mdx 词典失效。非本次引入，未改。
  - 用户那本词典的条目 HTML 还引用了 `oaldpex_img.js` / `oaldpex_word.js` / `oaldpex_sen.js` / `oaldpex_tts.js`，这四个**既不在 .mdd 也不在 zip 里**，是词典包自身缺的（欧路里同样会 404），与本 bug 无关。
  - 媒体能取到 ≠ 脚本会执行。词典自带 JS 仍然从不执行，见 [[BUG-2052]] 备注与后续的词典脚本执行工作。
