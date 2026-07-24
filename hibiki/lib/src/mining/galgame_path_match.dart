/// galgame 游玩计时的**纯路径归属判定**（见
/// `docs/design/galgame-library-reina-parity.md` §3）。
///
/// 计时器要回答的唯一问题是「某个进程的 exe 是不是这个游戏目录下的」。裸
/// `startsWith` 在这里是错的：`C:\Games\Game` 会把 `C:\Games\Game2\x.exe` 也认成
/// 自己的进程，于是隔壁游戏的前台时间被记到本作头上。正确做法是**按路径组件比较**，
/// 顺带把 Windows 那几件事一次性归一掉（`\` 与 `/` 等价、大小写不敏感、尾斜杠、
/// `.` / `..` 段）。
///
/// 这里全是纯函数，不碰文件系统、不碰平台 API，三端都能跑单测。符号链接解析
/// （`canonicalize`）属于 IO，由调用方在外层做完再把两条路径都送进来比。
library;

/// 把路径切成可比较的归一化组件序列。
///
/// - `\` 与 `/` 一律当分隔符；
/// - 丢掉空段（尾斜杠、连续斜杠）与 `.` 段；
/// - `..` 弹掉上一段（顶到头则原样保留，避免把 `../x` 静默变成 `x`）；
/// - 全部小写（Windows 文件系统大小写不敏感，galgame 场景同样）。
///
/// 盘符会成为独立的首段（`C:\a` → `['c:', 'a']`），因此不同盘的同名目录不会互相
/// 匹配。UNC 路径 `\\server\share\a` 的前导空段被丢弃后为 `['server','share','a']`，
/// 同样可比。
List<String> galgamePathComponents(String path) {
  final List<String> components = <String>[];
  for (final String raw in path.replaceAll('\\', '/').split('/')) {
    final String segment = raw.trim();
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (components.isNotEmpty && components.last != '..') {
        components.removeLast();
      } else {
        components.add('..');
      }
      continue;
    }
    components.add(segment.toLowerCase());
  }
  return components;
}

/// [candidate] 是否位于目录 [directory] 之内（按路径组件前缀比较）。
///
/// [includeSelf] 为 true 时，`candidate == directory` 也算命中（默认 true：目录
/// 本身被当成 exe 路径传进来时不该被判成「不在自己里面」）。
///
/// [directory] 归一化后为空（空串、纯斜杠）时恒返回 false——空目录若被当成
/// 「任何路径的父目录」，整个逃逸检测就退化成全匹配。
bool galgamePathIsWithin(
  String candidate,
  String directory, {
  bool includeSelf = true,
}) {
  final List<String> parent = galgamePathComponents(directory);
  if (parent.isEmpty) return false;
  final List<String> child = galgamePathComponents(candidate);
  if (child.length < parent.length) return false;
  if (child.length == parent.length && !includeSelf) return false;
  for (int i = 0; i < parent.length; i++) {
    if (child[i] != parent[i]) return false;
  }
  return true;
}
