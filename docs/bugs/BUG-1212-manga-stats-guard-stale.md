## BUG-1212 · 漫画统计守卫仍钉旧口径 charsRead: 0，PR#504 后 develop 变红
- **报告**：2026-07-28（用户：内部，develop 全量套件 4256 条中的一条红）
- **真实性**：✅ 真 bug（性质是**契约变更后守卫没跟上**，不是功能回归）。
  根因 `hibiki/test/media/manga_routing_guard_test.dart:94`（旧断言 `src.contains('charsRead: 0')`）
  对应实现侧 `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:1810`
  （PR#504 / commit `62d0cc8ad` 把 `charsRead: 0` 字面量换成 `charsRead: charsRead`，
  并新增 `pagesRead: pagesRead`，schema v60）。
  归属证据：合入前 `d9d95cf0a` 单跑该文件 PASSED - 12 tests；合入点 `1ca0ef0ad` 单跑
  同一文件 FAILED（唯一失败就是这条）。
- **[x] ① 已修复** — 守卫断言从「钉字面量 `charsRead: 0`」改为「钉两个量纲的接线不交叉」。
  旧断言的 reason 混了两件事：(A)「漫画无字数」是旧统计口径，产品决策已改为统计纳入
  漫画/视频/游戏，漫画字数取 mokuro / 内置 OCR 实义字符（与 EPUB 同源的
  `japaneseCharCount`），恒 0 反而是错的；(B)「页数不得塞进 charsRead」仍然成立，是这条
  守卫真正在守的不变量，PR#504 正是用 v60 新增的独立 `pagesRead` 列来兑现它。
  新守卫保留并**加强** (B)：断言字数来自 `mangaAccumulateReadingStats`、`charsRead:`
  与 `pagesRead:` 各自落各自的列，且显式否证四种交叉接线写法
  （`charsRead: pagesRead` / `charsRead: _sessionPagesRead` / `pagesRead: charsRead` /
  `_sessionCharsRead += added.pages` / `_sessionPagesRead += added.chars`）。
  实现侧一行未改。
- **[x] ② 已加自动化测试** — 同文件 `hibiki/test/media/manga_routing_guard_test.dart`
  的 `漫画阅读统计：字数走 OCR 记账、页数走独立列，两个量纲不交叉`。
  已做变异验证：把实现改成 `charsRead: pagesRead` 后该守卫立刻变红（确认是加强而非放宽），
  改回后 PASSED - 12 tests。
- **备注**：PDF 侧 `reader_pdf_routing_guard_test.dart` 的同名 `charsRead: 0` 断言**不受影响**，
  PDF 仍无字数口径（`reader_pdf_page.dart:251` 保持 `charsRead: 0`），本次不动。
