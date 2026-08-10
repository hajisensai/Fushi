/// 用户自定义显示名（「改名」）偏好 key 的固定前缀——**该字符串的唯一真相源**。
///
/// 书（EPUB / 漫画 / PDF / SRT 有声书）的改名不改 `epub_books.title` 列：那一列
/// 派生出主键 `bookKey`（= `sanitizeTtuFilename(title)`），改列等于换身份、十来张
/// 子表连坐改键。改名因此写成一行覆盖偏好，落库形态是
/// `src:<sourceId>:override_title://<mediaIdentifier>`（外层命名空间由
/// `dbSourcePrefKey` 拼，短 key 由 `MediaSource.overrideTitleKeyFor` 拼）。
///
/// 本文件**刻意零 import**：认这个前缀的不止 `MediaSource` 自己，还有三处远离
/// UI 层的消费方（BUG-1488）——互联 host 清单的 displayTitle 下发、备份导出的
/// settings 谓词、备份合并导入的内容合并。让它们去 import `media_source.dart`
/// 会把整个 `pages` barrel 拖进纯 DB 层；各自硬编码字符串则迟早漂开。
///
/// ⚠️ 这是持久化 key 编码：格式绝不能变（变了即丢用户改过的名字，never break
/// userspace）。
const String kOverrideTitleKeyMarker = 'override_title://';
