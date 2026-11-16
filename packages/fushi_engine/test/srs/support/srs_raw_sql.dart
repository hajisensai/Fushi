/// 测试专用：在 srs.db 的原始测试通道（[SrsCore.debugSelectRaw] / [SrsCore.debugExecRaw]，内核 `ffsrs_store_exec`
/// mode 5 / 4，走写连接）上套一层 Drift 式的外形（`customSelect(...).get()` / `getSingle()`、`QueryRow` 式的
/// `read<T>`），让直接看表的旧断言少改。
///
/// 生产代码里 srs.db 没有 SQL 句柄：读只有内核读命令（packages/fushi_engine/lib/srs/srs_reads.dart），写只有内核
/// 命令。这里只给测试核对表里的原始状态用。
///
/// ID 参数：[srsIdType] 绑定的 `Variable<String>` 按内核 ids.rs 的编码打包成 16 字节（规范小写 UUID）或原文本；
/// 直接选出的 ID 列（声明类型 UUIDTEXT）由内核还原成文本，表达式列自己套 `srs_idt(...)`。
library;

import 'dart:typed_data';

import 'package:drift/drift.dart'
    show CustomSqlType, DriftDatabaseOptions, GenerationContext, Variable;
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

/// ID 参数的类型（测试专用；生产代码不再有 srs.db 的 Drift 类型）。
const SrsTestIdType srsIdType = SrsTestIdType();

/// 见 [srsIdType]。
final class SrsTestIdType implements CustomSqlType<String> {
  const SrsTestIdType();

  @override
  String mapToSqlLiteral(String dartValue) =>
      "'${dartValue.replaceAll("'", "''")}'";

  @override
  Object mapToSqlParameter(String dartValue) =>
      packSrsTestId(dartValue) ?? dartValue;

  @override
  String read(Object fromSql) => fromSql is Uint8List && fromSql.length == 16
      ? _unpack(fromSql)
      : fromSql as String;

  @override
  String sqlTypeName(GenerationContext context) => 'UUIDTEXT';
}

int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// 规范小写带连字符 UUID 文本 → 16 字节；别的文本 null（与 Rust `ids::pack` 相同）。
Uint8List? packSrsTestId(String s) {
  if (s.length != 36) return null;
  final Uint8List out = Uint8List(16);
  int k = 0;
  int i = 0;
  while (i < 36) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (s.codeUnitAt(i) != 0x2d) return null;
      i++;
      continue;
    }
    final int hi = _nibble(s.codeUnitAt(i));
    final int lo = _nibble(s.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) return null;
    out[k++] = (hi << 4) | lo;
    i += 2;
  }
  return out;
}

String _unpack(Uint8List b) {
  const String hex = '0123456789abcdef';
  final StringBuffer s = StringBuffer();
  for (int i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s
      ..write(hex[b[i] >> 4])
      ..write(hex[b[i] & 15]);
  }
  return s.toString();
}

final GenerationContext _context = GenerationContext(
  DriftDatabaseOptions(),
  null,
);

/// Drift 变量 → 原始通道的参数（[srsIdType] 的经它的 `mapToSqlParameter` 打包；bool → 0/1 等同 Drift）。
List<Object?> _params(List<Variable<Object>> variables) => <Object?>[
  for (final Variable<Object> v in variables) v.mapToSimpleValue(_context),
];

/// 一行结果（Drift `QueryRow` 的测试外形）。
final class SrsRawRow {
  const SrsRawRow(this.data);

  final Map<String, Object?> data;

  /// 列 [key] 的值；`bool` 从 0/1 转，`double` 从整数转。列为 NULL 时 [T] 须可空。
  T read<T>(String key) {
    final Object? v = data[key];
    if (v is int && (<T>[] is List<bool> || <T>[] is List<bool?>)) {
      return (v != 0) as T;
    }
    if (v is int && (<T>[] is List<double> || <T>[] is List<double?>)) {
      return v.toDouble() as T;
    }
    return v as T;
  }

  T? readNullable<T>(String key) => data[key] == null ? null : read<T>(key);
}

/// `customSelect` 的结果（Drift `Selectable` 的测试外形）。
final class SrsRawSelect {
  SrsRawSelect._(this._core, this._sql, this._args);

  final SrsCore _core;
  final String _sql;
  final List<Object?> _args;

  Future<List<SrsRawRow>> get() async => <SrsRawRow>[
    for (final Map<String, Object?> r in _core.debugSelectRaw(_sql, _args))
      SrsRawRow(r),
  ];

  Future<SrsRawRow> getSingle() async => (await get()).single;

  Future<SrsRawRow?> getSingleOrNull() async {
    final List<SrsRawRow> rows = await get();
    return rows.isEmpty ? null : rows.single;
  }
}

/// srs.db 原始测试通道上的 Drift 式外形（见库文档）。
extension SrsRawSql on SrsCore {
  SrsRawSelect customSelect(
    String sql, {
    List<Variable<Object>> variables = const <Variable<Object>>[],
    Object? readsFrom,
  }) => SrsRawSelect._(this, sql, _params(variables));

  /// 一条写语句（测试造数 / 破坏现场用）。
  Future<void> customStatement(String sql, [List<Object?>? args]) async {
    debugExecRaw(sql, args ?? const <Object?>[]);
  }
}
