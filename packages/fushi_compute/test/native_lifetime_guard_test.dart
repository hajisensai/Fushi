// 原生内存生命周期的静态守卫（HBK-AUDIT-002 / 004）：
//
// 1. lib/ 里长寿命的原生内存只能由 NativeScratch 持有（分配即挂 NativeFinalizer、isolate
//    退出时释放）：不许把 malloc / calloc 的结果直接存进字段或顶层变量——那样的块只在扩容
//    时 free 旧块，短命 isolate 退出后永远不还。按调用 malloc、finally 里 free 的局部变量不受限。
// 2. 持有 NativeScratch 字段、或在类体里 attach NativeFinalizer 的类必须 implements
//    Finalizable：从 owner 取出的裸地址交给原生侧时，owner（经 this）在方法执行期间保活。
// 3. 不许用 `asTypedList(..., finalizer: ...)` 把释放挂在一个视图上、再单独把裸指针交给
//    原生侧（FfcEnergyEnvelope 原先的写法：视图不在保活域里，FFI 期间可能被提前释放）。
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final Directory _lib = Directory('lib');

List<File> _sources() =>
    _lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));

bool _isScratchOwner(File f) =>
    f.uri.pathSegments.last == 'native_scratch.dart';

/// 去掉 `//` 注释（守卫只看代码）。
String _code(String line) {
  final int at = line.indexOf('//');
  return at < 0 ? line : line.substring(0, at);
}

/// 一个类的头与类体行（从 `class` 行到下一个列 0 的 `}`）。
typedef _ClassBlock = ({String name, String header, List<String> body});

List<_ClassBlock> _classes(List<String> lines) {
  final RegExp head = RegExp(
    r'^(?:(?:final|sealed|abstract|base|interface|mixin)\s+)*class\s+(\w+)',
  );
  final List<_ClassBlock> out = <_ClassBlock>[];
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? m = head.firstMatch(lines[i]);
    if (m == null) continue;
    final StringBuffer header = StringBuffer();
    int j = i;
    while (j < lines.length && !lines[j].contains('{')) {
      header.write('${lines[j]} ');
      j++;
    }
    if (j < lines.length) header.write(lines[j]);
    final List<String> body = <String>[];
    int k = j + 1;
    while (k < lines.length && !lines[k].startsWith('}')) {
      body.add(_code(lines[k]));
      k++;
    }
    out.add((name: m.group(1)!, header: header.toString(), body: body));
    i = k;
  }
  return out;
}

/// 去掉字符串字面量内容（花括号计数用；插值里的花括号一并忽略）。
String _stripStrings(String code) => code
    .replaceAll(RegExp(r"'[^']*'"), "''")
    .replaceAll(RegExp(r'"[^"]*"'), '""');

/// 每行开头所处的作用域是否是「成员级」：顶层或类体（而不是函数 / 方法体）。
List<bool> _memberScope(List<String> lines) {
  final RegExp classHead = RegExp(
    r'^\s*(?:(?:final|sealed|abstract|base|interface|mixin)\s+)*class\s+\w+',
  );
  final List<bool> out = <bool>[];
  final List<bool> stack = <bool>[]; // true = class 体
  bool pendingClass = false;
  for (final String raw in lines) {
    out.add(stack.isEmpty || stack.last);
    final String line = _stripStrings(raw);
    if (classHead.hasMatch(line)) pendingClass = true;
    for (int i = 0; i < line.length; i++) {
      final String ch = line[i];
      if (ch == '{') {
        stack.add(pendingClass);
        pendingClass = false;
      } else if (ch == '}' && stack.isNotEmpty) {
        stack.removeLast();
      }
    }
  }
  return out;
}

void main() {
  test('long-lived native memory is owned by NativeScratch only', () {
    // 成员级（顶层 / 类体）的 Pointer 声明直接初始化成 malloc / calloc。
    final RegExp declared = RegExp(
      r'^\s*(?:static\s+)?(?:late\s+)?(?:final\s+)?Pointer<[^=]*>\s+(\w+)\s*=\s*(?:malloc|calloc)\s*[<(]',
    );
    // 构造函数初始化列表里给字段赋 malloc / calloc。
    final RegExp initializer = RegExp(
      r'^\s*[:,]\s*(\w+)\s*=\s*(?:malloc|calloc)\s*[<(]',
    );
    // 成员级的 Pointer 声明（之后在方法里被重新赋成 malloc / calloc 也算）。
    final RegExp pointerField = RegExp(
      r'^\s*(?:static\s+)?(?:late\s+)?(?:final\s+)?Pointer<[^;=]*>\s+(\w+)\s*(?:=|;)',
    );
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final File f in _sources()) {
      if (_isScratchOwner(f)) continue;
      scanned++;
      final List<String> lines = f.readAsLinesSync().map(_code).toList();
      final List<bool> member = _memberScope(lines);
      final Set<String> fields = <String>{
        for (int i = 0; i < lines.length; i++)
          if (member[i]) ?pointerField.firstMatch(lines[i])?.group(1),
      };
      for (int i = 0; i < lines.length; i++) {
        final String l = lines[i];
        final String where = '${f.path}:${i + 1}: ${l.trim()}';
        if ((member[i] && declared.hasMatch(l)) || initializer.hasMatch(l)) {
          offenders.add(where);
          continue;
        }
        if (member[i]) continue;
        for (final String name in fields) {
          final RegExp reassigned = RegExp(
            '^\\s*(?:this\\.)?$name\\s*=\\s*(?:malloc|calloc)\\s*[<(]',
          );
          if (reassigned.hasMatch(l)) offenders.add(where);
        }
      }
    }
    expect(scanned, greaterThan(20), reason: 'guard must scan lib/');
    expect(
      offenders,
      isEmpty,
      reason:
          'store long-lived native memory in a NativeScratch '
          '(lib/src/native_scratch.dart), not a raw malloc/calloc field',
    );
  });
  test('classes owning native memory implement Finalizable', () {
    final RegExp scratchField = RegExp(
      r'^ {2}(?:static\s+)?(?:late\s+)?(?:final\s+)?NativeScratch\s+\w+',
    );
    final List<String> owners = <String>[];
    final List<String> offenders = <String>[];
    for (final File f in _sources()) {
      for (final _ClassBlock c in _classes(f.readAsLinesSync())) {
        final bool holdsScratch = c.body.any(
          (String l) => scratchField.hasMatch(l) && !l.contains('static'),
        );
        final bool attaches = c.body.any((String l) => l.contains('.attach('));
        if (!holdsScratch && !attaches) continue;
        owners.add(c.name);
        if (!RegExp(r'implements[^{]*\bFinalizable\b').hasMatch(c.header)) {
          offenders.add('${f.path}: class ${c.name}');
        }
      }
    }
    // 自检：守卫确实认出了这些 owner（防正则失效后恒绿）。
    expect(
      owners,
      containsAll(<String>[
        'NativeScratch',
        'FfcEnergyEnvelope',
        'FushiComputeCrypto',
        'AacsNativeDecoder',
        'AudioTextFoldNative',
        'FfcStreamingHash',
      ]),
    );
    expect(offenders, isEmpty);
  });

  test('no finalizer is hung on a typed-data view of native memory', () {
    final List<String> offenders = <String>[];
    for (final File f in _sources()) {
      final String code = f.readAsLinesSync().map(_code).join('\n');
      for (final RegExpMatch m in RegExp(
        r'asTypedList\([^)]*finalizer\s*:',
      ).allMatches(code)) {
        offenders.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty);
  });
}
