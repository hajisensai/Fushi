# Per-Book CSS Editor

## 概述

允许用户查看和编辑 EPUB 书籍自带的 CSS 文件，按文件分 Tab 编辑，支持重置到原始状态。

## 入口

`ReaderHoshiHistoryPage.extraActions()` 新增「编辑书籍 CSS」动作，与现有 EPUB 专用动作（有声书导入、插图等）放在一起。按钮在 `bookId != null` 时始终显示（`extraActions()` 是同步方法，无法调用异步 `bookExists()`）。点击时异步调用 `EpubStorage.bookExists()` 校验，目录不存在则 toast 提示。通过 `EpubStorage.bookPath()` 定位 extractDir（不用 `bookDirectory()` 以避免创建空目录）。不修改通用 `MediaItemDialogPage`。

## 数据模型

**零数据库改动。** 用文件系统表达状态：

- 原始 CSS 备份：`{css_path}.original`（首次保存且内容真正变化时创建）
- 修改后的 CSS：写回原路径
- `.original` 的语义是「恢复基线」，不是「是否修改过」
- 判断是否与原始不同：比较当前文件内容与 `.original` 内容（`isDifferentFromOriginal`）
- 保存时如果内容等于 `.original`，删除 `.original`（自动恢复为「未修改」状态）
- 重置：把 `.original` 拷回原路径，删除 `.original`

### CSS 文件模型

```dart
class CssFileEntry {
  final String absolutePath;      // 磁盘绝对路径
  final String relativePath;      // 相对 extractDir 的路径（内部 identity）
  final String displayTitle;      // 最短唯一后缀（用于 Tab 显示）
  final String? originalPath;     // .original 备份路径（null = 无备份）
  final bool hasOriginal;         // .original 文件是否存在
  final bool isDifferentFromOriginal; // 当前内容是否与 .original 不同
}
```

## CSS 文件发现

扫描 `extractDir` 下所有 `.css` 文件（递归），排除 `.original` 后缀文件。

### Tab 标题去重

用「最短唯一后缀」算法避免 basename 撞名：
- 只有一个 `style.css` → 显示 `style.css`
- 两个 `style.css` 分别在 `OEBPS/Styles/` 和 `OEBPS/Alt/` → 显示 `Styles/style.css` 和 `Alt/style.css`

## extractDir 获取

通过 `ReaderHoshiSource.parseBookId()` 拿 bookId，再用 `EpubStorage.bookPath()` 定位目录。**不使用 `EpubStorage.bookDirectory()`**——它会创建目录，坏 bookId 会创建空目录。点击按钮时用 `EpubStorage.bookExists()` 异步校验。

## UI 结构

### BookCssEditorPage

```
┌─────────────────────────────────┐
│ ← 编辑书籍 CSS      [重置全部] │  AppBar
├──────────┬──────┬───────────────┤
│*Styles/  │fonts │page          │  TabBar（最短唯一后缀，* = 与原始不同）
│ style    │      │              │
├──────────┴──────┴───────────────┤
│                                 │
│  CSS 代码文本框                 │  TextField (monospace, maxLines)
│  （可滚动编辑）                 │
│                                 │
├─────────────────────────────────┤
│ [重置当前]           [保存]     │  BottomBar
└─────────────────────────────────┘
```

- `TextField` 使用等宽字体
- Tab 标题 `*` 表示「当前内容与 .original 不同」，通过内容比较得出
- 「重置当前」：仅重置当前 Tab 的 CSS 文件
- 「重置全部」：重置所有有 `.original` 备份的文件
- 「保存」：保存当前 Tab 的修改

### 安全写入

写入流程：write temp → flush → rename。备份失败则不写入，避免 CSS 被半截写坏。

```
1. 如果 .original 不存在 且 新内容 != 当前磁盘内容 → 备份当前文件为 .original
2. 写入 temp 文件 → flush → rename 到目标路径
3. 如果新内容 == .original 内容 → 删除 .original
```

### 未保存修改处理

所有离开当前编辑内容的操作都要处理未保存修改：

| 触发 | 行为 |
|------|------|
| 切换 Tab | 弹窗：保存 / 丢弃 / 取消 |
| 返回键 / 关闭页面 | 弹窗：保存 / 丢弃 / 取消 |
| 重置当前 | 弹窗确认后直接执行（丢弃编辑 + 恢复 .original） |
| 重置全部 | 弹窗确认后执行所有文件重置 |

## 对 WebView 的影响

**零改动。** 现有 `_interceptRequest` 从 `extractDir` 读取 CSS 并 serve。编辑器展示的是磁盘原始 CSS；WebView serve 时仍会经过 `ReaderResourceSanitizer.sanitizeCss()`（例如 `-epub-writing-mode` 会被移除）。用户需要重新打开书籍才能看到变化。

## 国际化

所有用户可见文案走 Slang（`t.*`），使用 flat key（与项目现有风格一致）：

- `t.book_css_editor_title` — 页面标题
- `t.book_css_editor_edit_css` — 长按菜单按钮文案
- `t.book_css_editor_reset_current` — 重置当前
- `t.book_css_editor_reset_all` — 重置全部
- `t.book_css_editor_save` — 保存
- `t.book_css_editor_no_css_files` — 空状态提示
- `t.book_css_editor_unsaved_changes` — 未保存修改弹窗标题
- `t.book_css_editor_unsaved_changes_message` — 未保存修改弹窗内容
- `t.book_css_editor_confirm_reset` — 重置确认弹窗
- `t.book_css_editor_confirm_reset_all` — 重置全部确认弹窗
- `t.book_css_editor_discard` — 丢弃
- `t.book_css_editor_cancel` — 取消
- `t.book_css_editor_saved` — 保存成功提示
- `t.book_css_editor_reset_done` — 重置成功提示
- `t.book_css_editor_no_extract_dir` — 提取目录不存在提示

## 文件清单

| 新文件 | 职责 |
|--------|------|
| `book_css_editor_page.dart` | CSS 编辑页面，Tab 编辑器 + 保存/重置 |
| `book_css_repository.dart` | CSS 文件发现、读取、写入、备份、重置、内容比较 |

| 修改文件 | 改动 |
|----------|------|
| `reader_hoshi_history_page.dart` | `extraActions()` 新增「编辑书籍 CSS」按钮 |
| `strings.i18n.json` | 新增 `book_css_editor_*` flat key（其他 locale 文件由 Slang fallback 自动覆盖，不需手动修改） |

## 边界情况

- EPUB 没有 CSS 文件：显示空状态提示
- CSS 文件编码：统一 UTF-8 读写（与现有 sanitize 逻辑一致）
- extractDir 不存在：点击按钮时 `bookExists()` 返回 false，toast 提示
- Tab basename 撞名：用最短唯一后缀
- 保存内容恢复为原始：自动删除 `.original`，状态回归未修改

## 测试

`BookCssRepository` 单测覆盖：

- 发现 CSS 文件（含递归、排除 .original）
- Tab 显示名去重（basename 撞名场景）
- 首次保存创建 .original 备份
- 保存内容等于 .original 时自动删除备份
- 重置当前文件
- 重置全部文件
- extractDir 不存在时返回空列表
- 安全写入（temp → rename）
