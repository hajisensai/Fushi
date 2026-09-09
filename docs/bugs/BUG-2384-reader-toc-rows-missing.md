## BUG-2384 · 阅读器目录章节列表显示不全（少行 / 整段消失）
- **报告**：2026-09-09（用户：移动端目录「显示不全」）
- **真实性**：✅ 真 bug，两条独立根因，都与平台无关（移动端因为可视高度小更容易被看见）：
  1. **同一个 `GlobalKey` 挂到多行 → 真的少一行。**
     `fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:1166`（修前）
     `key: !toc[i].isHeader && currentIdx == toc[i].index ? _currentTocRowKey : null`
     —— 判据是「index 命中当前章」，而**同一 spine 章有多条目录项是常态**
     （一个 xhtml 装整卷、目录靠 `#anchor` 分节，见 BUG-2383：`normalizeHref` 切掉
     `#…` 后它们的章号全相同）。同一个 GlobalKey 出现在两个在场 widget 上，debug 抛
     `Multiple widgets used the same GlobalKey`，release 则由
     `Element._retakeInactiveElement` 把 element 从前一行手里抢走
     （`parent.forgetChild` + `deactivateChild`）——那一行被摘出渲染树。
  2. **解析期整棵子树被丢掉。** `fushi/lib/src/epub/epub_parser.dart:709`（修前）
     `if (label != null && label.isNotEmpty)` 才收这条 `<li>`：
     - `<a>` 里只有 `<img>` 的**图片目录项**（画廊 / 漫画 / 扉页）`innerText` 为空 → 整条丢；
     - 更糟的是 `children` 已经解析好了却跟着一起被扔——一个**无名分组节点**
       （`<li>` 只有 `<ol>`，没有 `<a>`/`<span>`）就能让它名下所有章节从目录里消失。
     NCX 侧 `_parseNavPoints` 的 `if (label.isNotEmpty)` 同形。
- **[x] ① 已修复** — 本提交：
  - 目录行的 GlobalKey 只挂**第一条**命中当前章的行（`toc.indexWhere(...)`），
    它同时也是「打开即滚到当前章」的滚动锚点。多行高亮（`selected`）不变。
  - `_parseNavOl`：`<a>` 无文本时用 `<img>` 的 `alt` / `title` 命名（新增
    `_imageLabelWithin`）；仍取不到名字时**只丢这一条自己**，`children` 并入上一层。
    `_parseNavPoints`（NCX）同样处理。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_toc_rows_missing_bug2384_test.dart`（本提交）：
  - **widget 行为**：pump 导航抽屉，目录里三条目录项同指当前章（只有锚点不同），
    断言四行标签**每一条都在屏上**——修复前红（GlobalKey 冲突）。
  - **解析层**：真造一个 EPUB（`<a><img alt="口絵"/></a>` + 一个无名分组 `<li>` 包着
    「第二章」），断言图片目录项按 alt 命名、无名分组名下的章节没有消失——修复前红。
  - 两条都用「先把修复回退再跑」实测确认过修复前红（连同 BUG-2383 那条，三条一起验的）。
- **验证**（按退出码判绿）：
  - `flutter analyze`（fushi，含 test / integration_test）→ No issues found。
  - `flutter test test/epub test/media/audiobook` → 1318 例全绿，exit=0。
  - `flutter test test/reader` → 1593 例通过；两条 headless Chrome 探针红在**基线上同红**
    （把本次 lib 改动全部 `git checkout` 掉复跑验证过），与本改动无关。
  - `flutter test test/tools` → 唯一的红是 `update_manifest_publish_race_test.dart`
    的 4 例，报错是 `WSL … execvpe(/bin/bash) failed`（本机 bash 环境），与本改动无关。
- **备注**：本机无可用 Android 模拟器 / 真机，移动端原始路径的肉眼复测未做。
  调查中还确认了两件事，**本次有意未动**：
  - `TtuTocEntry.depth` 全仓没有任何生产者恒为 0，于是目录层级折叠（`depth >= 2` 才
    折叠）整套是**从未生效的死代码**——但这也意味着谁要是「顺手」让 flatten 填上
    depth，嵌套条目会立刻默认隐藏，变成真正的折叠型「显示不全」。
  - 导航抽屉里目录排在「搜索 / 按字数跳转」之后。移动端软键盘弹起时可视高度只剩
    ~418px，目录基本在屏外——这条由 BUG-2382（不再自动弹键盘）解掉，本条不改版面顺序。
