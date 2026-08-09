// 守卫：`native/fushi_torrent` 的 C ABI 头文件与手写镜像的 Dart FFI 绑定必须
// 逐符号、逐参数对齐。
//
// 为什么需要它：`packages/fushi_torrent/lib/src/ffi/fushi_torrent_bindings.dart`
// 是**手写镜像**（`ffigen.yaml` 明确允许：本机没有 LLVM/libclang 时不跑 ffigen）。
// 手写就会漂，而 FFI 的漂移**不会**给你一个干净的报错：
// - 少写一个符号 → 用户运行时 `lookup` 抛（只有装了新 DLL 的用户才撞上）；
// - 参数个数写错 → `asFunction` 拿错误签名去调，是**未定义行为**（栈错位/内存损坏），
//   不是异常。
//
// 而这两件事在 CI 里原本**无人可挡**：`packages/fushi_torrent` 的测试要
// `FUSHI_TORRENT_LIB` 指向已构建的 DLL，Linux CI 没有 DLL → 整组 skip；
// 而 main.yml / release.yml 的包测试清单本就没收录这个包。
//
// 本守卫是**纯文本扫描**，不需要 DLL、不需要 native 工具链，因此能跟着主 app 测试
// 套件在任何平台的 CI 上跑 —— 这正是它存在的意义。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 头文件里一个导出函数的签名摘要。
class _CExport {
  const _CExport(this.name, this.paramCount);

  final String name;
  final int paramCount;
}

/// 按顶层逗号切分参数列表（尖括号/圆括号内的逗号不算）。
/// C 侧没有尖括号，但函数指针参数会有圆括号，一并处理。
int _countTopLevelParams(String params) {
  final String trimmed = params.trim();
  if (trimmed.isEmpty) return 0;
  // C 的 `(void)` = 无参。
  if (trimmed == 'void') return 0;
  int depth = 0;
  int count = 1;
  for (final int unit in trimmed.codeUnits) {
    final String ch = String.fromCharCode(unit);
    if (ch == '(' || ch == '<') depth++;
    if (ch == ')' || ch == '>') depth--;
    if (ch == ',' && depth == 0) count++;
  }
  return count;
}

/// 从 C 头文件抽出所有 `HT_EXPORT` 函数（跨行声明也能吃）。
List<_CExport> _parseHeader(String source) {
  final List<_CExport> out = <_CExport>[];
  // HT_EXPORT <返回类型…> ht_name( …参数… );
  final RegExp re = RegExp(
    r'HT_EXPORT\s+[^;(]*?\b(ht_\w+)\s*\(([^;]*?)\)\s*;',
    dotAll: true,
  );
  for (final RegExpMatch m in re.allMatches(source)) {
    out.add(_CExport(m.group(1)!, _countTopLevelParams(m.group(2)!)));
  }
  return out;
}

/// 从手写绑定里抽出每个 `_lookup<...>('ht_xxx')` 对应的 Dart 侧参数个数。
///
/// 取的是 `asFunction<Ret Function(...)>` 里的参数个数（真正决定调用约定的那个），
/// 而不是外层包装方法的形参 —— 包装方法写错顶多编译不过，`asFunction` 写错才是
/// 内存损坏。
Map<String, int> _parseBindings(String source) {
  final Map<String, int> out = <String, int>{};
  // late final _ht_xxx = _ht_xxxPtr.asFunction<Ret Function(params)>();
  final RegExp re = RegExp(
    r'_(ht_\w+)\s*=\s*_\1Ptr\s*\.?\s*asFunction<[^(]*?Function\((.*?)\)>\(\)',
    dotAll: true,
  );
  for (final RegExpMatch m in re.allMatches(source)) {
    out[m.group(1)!] = _countTopLevelParams(m.group(2)!);
  }
  return out;
}

/// 绑定里 `_lookup<...>('name')` 声明过的符号集合（查符号名是否齐）。
Set<String> _parseLookedUpSymbols(String source) {
  // 泛型实参是多层嵌套的（`_lookup<ffi.NativeFunction<... Function(...)>>`），
  // 别试图匹配尖括号配对 —— 用惰性跨行匹配吃到 `>(` 再取符号字面量。
  return RegExp(r"_lookup<[\s\S]*?>\(\s*'(ht_\w+)'")
      .allMatches(source)
      .map((RegExpMatch m) => m.group(1)!)
      .toSet();
}

void main() {
  // 测试的工作目录是 `fushi/`，native 与 packages 在它的上一级。
  final File headerFile =
      File('../native/fushi_torrent/fushi_torrent_include/fushi_torrent.h');
  final File bindingsFile =
      File('../packages/fushi_torrent/lib/src/ffi/fushi_torrent_bindings.dart');

  test('C ABI 头文件与手写 FFI 绑定：符号集合必须完全一致', () {
    expect(headerFile.existsSync(), isTrue,
        reason: '找不到 ${headerFile.path} —— 守卫失去意义，先修路径');
    expect(bindingsFile.existsSync(), isTrue,
        reason: '找不到 ${bindingsFile.path}');

    final List<_CExport> exports = _parseHeader(headerFile.readAsStringSync());
    expect(exports, isNotEmpty, reason: '头文件里一个 HT_EXPORT 都没解析到，正则失效了');

    final Set<String> exported = exports.map((_CExport e) => e.name).toSet();
    final Set<String> lookedUp =
        _parseLookedUpSymbols(bindingsFile.readAsStringSync());

    final Set<String> missing = exported.difference(lookedUp);
    expect(missing, isEmpty,
        reason: '这些 C 导出没有对应的 Dart 绑定：$missing\n'
            '新增 HT_EXPORT 之后必须同步 fushi_torrent_bindings.dart '
            '（本机有 LLVM 就 `dart run ffigen --config ffigen.yaml`，'
            '没有就照既有风格手写镜像）。漏了的话，只有装上新 DLL 的用户会在运行时'
            '撞到 lookup 抛异常。');

    final Set<String> stale = lookedUp.difference(exported);
    expect(stale, isEmpty,
        reason: '这些 Dart 绑定在 C 头文件里已不存在：$stale\n'
            '删/改 C ABI 符号时必须同步删掉绑定，否则 lookup 会在运行时抛。');
  });

  test('C ABI 头文件与手写 FFI 绑定：每个函数的参数个数必须一致', () {
    final List<_CExport> exports = _parseHeader(headerFile.readAsStringSync());
    final Map<String, int> bindings =
        _parseBindings(bindingsFile.readAsStringSync());

    final List<String> mismatches = <String>[];
    for (final _CExport e in exports) {
      final int? dartArity = bindings[e.name];
      if (dartArity == null) {
        mismatches.add('${e.name}: 绑定里没有 asFunction 签名');
        continue;
      }
      if (dartArity != e.paramCount) {
        mismatches.add('${e.name}: C 侧 ${e.paramCount} 个参数，'
            'Dart asFunction 写了 $dartArity 个');
      }
    }
    expect(mismatches, isEmpty,
        reason: '参数个数对不上：\n${mismatches.join('\n')}\n'
            '这不是「会报错」的那种错 —— asFunction 拿错误签名去调是**未定义行为**'
            '（栈错位/内存损坏），改 C ABI 参数后必须同步改绑定。');
  });
}
