// initState 裸挂外部资源扫描器（BUG-5604），守卫
// `initstate_resource_rollback_guard_test.dart` 与基线重写共用这一份实现。
//
// 只依赖 dart:io，可直接跑：在 fushi/ 下 `dart run test/build/initstate_resource_scan.dart`
// 按当前 lib/ 重写基线（只在裸挂变少、收紧基线时用）。
import 'dart:io';

void main() {
  File(initStateBaselineFile).writeAsStringSync(
    formatInitStateBaseline(scanInitStateRawAttachments(Directory('lib'))),
  );
}

const String initStateBaselineFile =
    'test/build/initstate_resource_rollback_baseline.txt';

final RegExp _attach = RegExp(
  r'\.listen\(|\.add\w*Listener\(|\.addObserver\(|\.addHandler\(|'
  r'\bTimer(\.periodic)?\(|\bAppLifecycleListener\(',
);
final RegExp _ownPrivateListener = RegExp(
  r'(?<![\w.])_\w*\??\.add\w*Listener\($',
);
final RegExp _ownConstructedListener = RegExp(
  r'^_\w+\s*=\s*[A-Z]\w*(<[^;]*?>)?\(',
);
final RegExp _registered = RegExp(r'\b(ownSubscription|listenTo|ownTimer)\(');
final RegExp _initState = RegExp(r'void\s+initState\(\)\s*\{');
final RegExp _classDecl = RegExp(r'\b(?:class|mixin)\s+(\w+)');

/// `lib/` 下每个类 initState 里裸挂的资源个数，键为 `相对路径::类名`。
Map<String, int> scanInitStateRawAttachments(Directory lib) {
  final Map<String, int> result = <String, int>{};
  final List<File> files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (File f) =>
                f.path.endsWith('.dart') &&
                !f.path.endsWith('.g.dart') &&
                !f.path.endsWith('.freezed.dart'),
          )
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String rel = file.path.replaceAll(r'\', '/');
    rawAttachmentsByClass(file.readAsStringSync()).forEach((
      String cls,
      int count,
    ) {
      result['$rel::$cls'] = (result['$rel::$cls'] ?? 0) + count;
    });
  }
  return result;
}

/// 单个源文件：类名 → initState 里裸挂的资源个数（0 的不出现）。
Map<String, int> rawAttachmentsByClass(String source) {
  final String code = _stripLineComments(source);
  final Map<String, int> result = <String, int>{};
  for (final RegExpMatch m in _initState.allMatches(code)) {
    final int bodyStart = m.end;
    final int bodyEnd = _matchingBrace(code, bodyStart);
    final String body = code.substring(bodyStart, bodyEnd);
    int count = 0;
    for (final RegExpMatch a in _attach.allMatches(body)) {
      final int stmtStart = body.lastIndexOf(';', a.start) + 1;
      final String head = body.substring(stmtStart, a.end);
      if (_registered.hasMatch(head)) continue;
      final String stmt = head.trimLeft();
      if (_ownPrivateListener.hasMatch(stmt)) continue;
      // `_ctrl = AnimationController(...)..addListener(...)`：自己新建的对象。
      if (a.group(0)!.startsWith('.add') &&
          _ownConstructedListener.hasMatch(stmt)) {
        continue;
      }
      final int stmtEnd = body.indexOf(';', a.end);
      if (stmtEnd >= 0 &&
          body.substring(stmtEnd + 1).trimLeft().startsWith('onTeardown(')) {
        continue;
      }
      count++;
    }
    if (count == 0) continue;
    final Iterable<RegExpMatch> classes = _classDecl.allMatches(
      code.substring(0, m.start),
    );
    final String cls = classes.isEmpty ? '?' : classes.last.group(1)!;
    result[cls] = (result[cls] ?? 0) + count;
  }
  return result;
}

String _stripLineComments(String source) => source
    .split('\n')
    .map((String line) {
      final int i = line.indexOf('//');
      // 字符串里的 `://`（URL）不当注释。
      if (i < 0 || (i > 0 && line[i - 1] == ':')) return line;
      return line.substring(0, i);
    })
    .join('\n');

int _matchingBrace(String code, int afterOpen) {
  int depth = 1;
  for (int i = afterOpen; i < code.length; i++) {
    final String c = code[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return code.length;
}

Map<String, int> parseInitStateBaseline(String text) {
  final Map<String, int> out = <String, int>{};
  for (final String raw in text.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int sp = line.lastIndexOf(' ');
    out[line.substring(0, sp)] = int.parse(line.substring(sp + 1));
  }
  return out;
}

String formatInitStateBaseline(Map<String, int> counts) {
  final List<String> keys = counts.keys.toList()..sort();
  return <String>[
    '# initState 裸挂外部资源的存量基线（BUG-5604），只许减不许增。',
    '# 由 test/build/initstate_resource_scan.dart 生成，守卫见 initstate_resource_rollback_guard_test.dart：',
    '# dart run test/build/initstate_resource_scan.dart（在 fushi/ 下）',
    for (final String k in keys) '$k ${counts[k]}',
    '',
  ].join('\n');
}
