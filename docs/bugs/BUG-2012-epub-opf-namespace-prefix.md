## BUG-2012 · 带 opf: 前缀的 OPF 导致 manifest/spine 解析为空、EPUB 导入失败
- **报告**：2026-09-01（用户：白夜行_backup.epub 导入不了）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/epub/epub_parser.dart:383`（`findAllElements('item')`）、`:416`（`'itemref'`）、`:364`（`'rootfile'`）、`:516`/`:795`（`'meta'`）、`:578`（`'spine'`）、`:673`（`'navMap'`）、`:609`（`'nav'`）、`:613`/`:699`（`getElement`）——全部按 **qualified name** 匹配。

  EPUB 规范只要求元素落在 OPF / OCF / NCX 命名空间里，**没规定必须用默认命名空间**。Calibre 4.x 导出的包文档写成带前缀的 `<opf:package><opf:manifest><opf:item/>`；而 package:xml 的 `findAllElements(name)` 在不传 `namespace` 时比较的是 qualified name（`name_matcher.dart` 的 `createNameMatcher`），`'item'` 匹配不到 `<opf:item>`。

  失败链：manifest 解析成空 map → `_parseSpine` 里每个 itemref 的 `manifest[idref]` 都是 null → 逐条 `continue`（**五条 spine 跳过判据一条日志都不打**）→ `chapters` 为空 → `:69` 抛 `FormatException('EPUB spine contains no readable chapters')` → `ImportFlowMixin.runImport` 弹一条 toast，用户看到的就是「这本 EPUB 导入不了」。

  同一文件里 `_parseMetadata`（`:492`）**唯独这一处**传了 `namespace: '*'`，注释还写着「matches any prefix」——作者知道这个坑，但只在 dc: 元数据那处修了；`_parseNavPoints` 用 `navPoint.name.local` 也是对的，但同函数的 `getElement('text')` 又漏了。是典型的补丁式局部修留下的不一致。

  **实测证据**（用户样本 `白夜行_backup.epub`，東野圭吾 / calibre 4.99.5，整份 OPF 带 `opf:` 前缀）：
  ```
  findAllElements('item')                 → 0      （加 namespace:'*' → 21）
  findAllElements('itemref')              → 0      （加 namespace:'*' → 17）
  findAllElements('spine') / ('meta')     → 0 / 0  （加 namespace:'*' → 1 / 3）
  ```
  修复前跑真解析器：`backup` 抛 `EPUB spine contains no readable chapters`；同书另一份用默认命名空间导出的 `白夜行.epub` 则解析正常（两份内容一致，只是 OPF 写法不同）。修复后两份都解析出 17 章 / 15 条目录 / 封面 / 作者，结果完全一致。

  两份样本的 zip 结构与 XML 语法都合规（mimetype 均为第一条目且 STORED、`testzip` 无损坏、所有 XML 都能解析），文件本身没坏。

- **[x] ① 已修复** — `epub_parser.dart` 新增三个查找原语 `_elements` / `_childElement` / `_attribute`（一律 `namespace: '*'`，按 local-name 匹配），并把文件内 **11 处**按标签名的查找全部收敛过去，含 `epub:type` 属性那处。修法刻意不是逐处补 `namespace: '*'`——那样下次新增查找还会漏第 12 处；改成让按 local-name 匹配成为本文件里**唯一**的查找方式，把「带前缀」从需要逐处记得处理的特殊情况变成不存在的情况。提交：见下方 commit。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_parser_namespace_test.dart`（6 条）：
  - 行为层 5 条：整份 `opf:` 前缀包文档解析出全部章节/标题/作者/语言/封面；带前缀与不带前缀结果**逐字段一致**；`ncx:` 前缀 NCX 的目录；`ocf:` 前缀 container.xml 的 rootfile（单独一份样本，避免被 OPF 那条掩盖）；EPUB 3 nav 的 `epub:type` 属性。样本刻意复刻用户文件的形状——OPF 在 **zip 根目录**而非 `OEBPS/`。
  - 源码层 1 条：扫 `epub_parser.dart` 禁止裸 `findAllElements('…')` / `getElement('…')`，并同时断言两个原语仍在（否则「一处调用都没有」会让前两条断言恒真空转）+ `_elements(` 调用数 > 5。判据先剥行注释，否则文档里解释这个坑的那几行会被自己命中成假红。
  - **变异实测**：① 把 `_elements` 退回裸调用 → 6 跑 5 红，抛的正是 `EPUB spine contains no readable chapters` / `no rootfile in container.xml`，守卫同时红；② 只在行为测试没覆盖的 `_parseRenditionSpread` 新增一处裸调用 → 5 条行为测试**全绿**、仅源码守卫红并点名 `findAllElements('meta')`，证明守卫确实补住了行为测试的盲区。两次变异后 `sha256` 均还原为 `25820fa8…83483`。
- **复核补充（2026-09-01，审查轮）**：
  - **向后兼容已实测钉住**。`namespace: '*'` 在 `package:xml` 里走的是「只比 local name、完全不看 namespaceUri」的匹配分支，所以从裸调用改成原语是**纯放宽**：带前缀的书从解析不了变成能解析，原本能解析的书（默认命名空间、以及**完全不写 `xmlns`** 的简陋档）一条都不会窄掉。新增行为用例「完全不写 xmlns 的简陋 EPUB 仍能解析」把这条性质固定下来。**变异实测**：把 `_elements` 改成「按 OPF 命名空间 URI 精确匹配」（一个看着更严谨、很可能被将来的人改成这样的写法）→ 该用例红并点名向后兼容回归；按唯一锚点还原后 sha256 回到 `fd95472d…b8e33`。
  - **补 `_attribute` 的守卫**。原守卫只拦裸 `findAllElements` / `getElement`，漏了**属性**这一路：`getAttribute('epub:type')` 这种硬编码前缀正是本 bug 的同一形态——`epub:` / `opf:` 只是惯例，XML 允许把同一命名空间绑到任意前缀。新增判据「属性名字面量里不许出现冒号」（无前缀属性按规范落在无命名空间里，裸 `getAttribute` 是对的，故只拦带冒号的）。**变异实测**：把 `_attribute(nav, 'type')` 退回 `getAttribute('type') ?? getAttribute('epub:type')` → **行为测试全绿、只有该守卫红**并打印 `getAttribute('epub:type'`，正说明它补的是行为测试够不着的盲区；还原后 sha256 一致。
  - **守卫的注释剥离改走共享原语**（阻断项）。原实现手写「跳过 `//` 开头整行」，被 `test/tools/source_guard_adoption_test.dart` 明令禁止——手写形态只管行首注释，行尾注释与 `/* */` 块注释一概放行，会让三条「原语必须还在」的锚点被「实现删光、注释里留同样字面量」骗绿。已改用 `test/helpers/source_guard.dart` 的 `maskComments`。

- **备注**：同一 `_resolveWithinExtract:748` 还有一个**独立的、未修的**同族漏洞：`p.join(opfDir, href)` 在 href 带前导 `/`（如 `/text/part0001.xhtml`）时会丢弃 `opfDir`（`p.join` 遇绝对路径段即丢弃前面所有段），结果落在 `extractDir` 外 → `p.isWithin` 为 false → 返回 null → spine 同样被逐条静默跳过 → 同一条 `no readable chapters`。同文件的 `_resolveTocHref:772` 明确写了 `.replaceFirst(RegExp('^/'), '')`、`normalizeHref` 也去前导斜杠，唯独导入必经的 manifest/spine/cover 这三条路没去。OPF 位于 zip 根目录的书最容易写成根绝对 href。**不是本 bug 的原因**（用户样本的 href 是 `text/part0001.xhtml`，不带前导斜杠），另行开号跟进，勿在本条下顺手改。
