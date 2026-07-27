/// Windows 文件名安全化的唯一真相源（命名统一 G1 收敛，BUG-1125）。
///
/// 统一字符集 = Windows 保留字符 `\ / : * ? " < > |` + 控制字符 `\x00-\x1f`
/// （POSIX 端仅 `/` 与 `\x00` 非法，取并集保证同一输入在 5 平台派生同名产物）。
/// 全仓禁止再手写该字符类（守卫 `test/tools/safe_file_name_guard_test.dart`）；
/// 需要「校验/拒绝」而非「替换」语义时，直接对 [windowsUnsafeFileNameChars]
/// `hasMatch`，不要复制字符集。
library;

/// Windows 非法文件名字符黑名单（含两种路径分隔符与控制字符）。
final RegExp windowsUnsafeFileNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

/// 把 [value] 中的非法文件名字符**逐个**替换为 `_`。
///
/// 刻意不折叠连续 `_`、不 trim、不处理保留设备名——调用方按各自既有产物命名
/// 契约自行叠加（如 `_+` 折叠、`.trim()`、空串回退），保证既有磁盘文件名/数据库
/// 键对全部现实输入字节不变。
String safeWindowsFileName(String value) =>
    value.replaceAll(windowsUnsafeFileNameChars, '_');
