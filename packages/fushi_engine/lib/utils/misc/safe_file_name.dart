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
/// 键对全部现实输入字节不变。需要避开保留设备名时另问 [isWindowsReservedFileName]。
String safeWindowsFileName(String value) =>
    value.replaceAll(windowsUnsafeFileNameChars, '_');

/// [name] 是否会被 Windows 当成保留设备名（`CON` / `PRN` / `AUX` / `NUL` /
/// `COM0-9` / `LPT0-9`，含上标 `¹²³` 变体）。
///
/// 按 Win32 命名规范判：第一个 `.` 之前的部分（去掉尾随空格、不分大小写）是设备名
/// 就算——`NUL.txt`、`NUL.tar.gz`、`CON .x` 都等价于设备本身；`CON (1)`、`CONSOLE`
/// 不是。命中时由调用方按自己的命名契约改写（常见做法是前缀 `_`）。
bool isWindowsReservedFileName(String name) => _windowsReservedDeviceNames
    .contains(name.split('.').first.trimRight().toUpperCase());

final Set<String> _windowsReservedDeviceNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  for (final String n in const <String>[
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '¹',
    '²',
    '³',
  ]) ...<String>['COM$n', 'LPT$n'],
};

/// 每个 Windows 非法文件名字符对应的全角替身（与 [windowsUnsafeFileNameChars]
/// 同一字符集；控制字符没有可读替身，直接删掉）。
const Map<String, String> _fullwidthReplacements = <String, String>{
  r'\': '＼',
  '/': '／',
  ':': '：',
  '*': '＊',
  '?': '？',
  '"': '＂',
  '<': '＜',
  '>': '＞',
  '|': '｜',
};

/// 面向**用户可读文件名**的安全化（视频「整理文件名」，反馈 ZDYNkAP3Ln）：非法
/// 字符换成全角替身（`Re:` → `Re：`、`?` → `？`），控制字符删掉，再去掉 Windows
/// 不允许的尾随 `.` / 空格；命中保留设备名时前缀 `_`。
///
/// 与 [safeWindowsFileName] 的区别是**语义保真**：`_` 替换会把 `Re:Re:` 变成
/// `Re_Re_`，标题读不出来了；全角替身在 5 平台都是合法字符，读起来与原标题一致。
/// 已有产物（下载整理、缓存键）继续用 [safeWindowsFileName]，它们的磁盘名 / 键
/// 是持久契约，不能因为换替身而改变。结果为空串时返回空串，由调用方决定回退。
String fullwidthSafeFileName(String value) {
  String out = value.replaceAllMapped(
    windowsUnsafeFileNameChars,
    (Match m) => _fullwidthReplacements[m[0]!] ?? '',
  );
  out = out.trim().replaceAll(RegExp(r'[. ]+$'), '');
  if (out.isNotEmpty && isWindowsReservedFileName(out)) out = '_$out';
  return out;
}
