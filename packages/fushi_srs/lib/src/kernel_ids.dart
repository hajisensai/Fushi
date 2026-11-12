/// 根上的 ID 与同步目录名一律向内核要（docs/specs/2026-11-11-srs-generation-break.md §5.1、§5.2、G5）。
///
/// 规则表只在内核一处（native/fushi_fsrs/src/gen4_ids/rules.rs）；Dart 不再自己拼「`<uid>/note/<guid>`」这类带盐的
/// 名字，也不再按 uid 拼同步目录（`fushi-srs/<uid>/`）。用哪个盐、目录叫什么由内核按 profile 决定
/// （gen4_ids/derive.rs 的 `salt_of` / `location_dir_of`）：协议 4 切换（G7）之前仍是存量规则，答的值与改造前 Dart
/// 算的逐字节相同；G7 起内核改查集合绑定（绑定在 srs.db 里，到时这个入口要连到 store），调用方都经这里问，
/// 改动收在这一处。
///
/// 一批一次 FFI（[SrsKernelIds.ask]），同步调用（纯函数，不碰库），原生库是硬依赖：加载失败抛
/// [SrsKernelIdsUnavailableError]，没有 Dart 回退。由父 ID 派生、不带盐的规则（字段、模板、卡、导入日志……）
/// 仍在 [SrsIds]。
library;

import 'dart:convert';

import 'ffi/ffi_fsrs_engine.dart';
import 'ffi/fushi_fsrs_library.dart';

/// 原生库加载失败：向内核要 ID 没有 Dart 回退。
final class SrsKernelIdsUnavailableError extends StateError {
  SrsKernelIdsUnavailableError()
    : super(
        'fushi_fsrs native library unavailable: SRS ids come from the kernel',
      );
}

/// 「不合并笔记类型」导入时，来源笔记类型里一个字段 / 模板的身份：[configId] 有就用它，没有用 [name]。
typedef SrsDupPart = ({int? configId, String name});

/// 一个 profile 的根上 ID（笔记、笔记类型、牌组、内置实体）与同步目录名。
final class SrsKernelIds {
  SrsKernelIds(this.profileUid, {FushiFsrs? library}) : _library = library;

  /// 问的是哪个 profile（内核据此决定盐与目录名；Dart 不拿它拼名字）。
  final String profileUid;

  final FushiFsrs? _library;

  static FfiFsrsEngine? _shared;

  static FfiFsrsEngine _engine(FushiFsrs? library) {
    if (library != null) return FfiFsrsEngine(library);
    final FfiFsrsEngine? cached = _shared;
    if (cached != null) return cached;
    final FushiFsrs lib =
        FushiFsrs.instance ?? (throw SrsKernelIdsUnavailableError());
    return _shared = FfiFsrsEngine(lib);
  }

  /// Dart 字符串里落单的代理项编码成 UTF-8 时记作 U+FFFD（改造前的派生就是对 `utf8.encode` 的结果哈希）；
  /// JSON 往返前先换掉，内核拿到的是同一串字节。
  static String _wellFormed(String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDFFF) return utf8.decode(utf8.encode(s));
    }
    return s;
  }

  /// 一批请求一次 FFI：每项 `[种类, 参数…]`（种类与参数见 gen4_ids/derive.rs），结果逐项对应。
  /// 字符串参数先换掉落单的代理项（[_wellFormed]）。
  List<Object?> ask(List<List<Object?>> items) =>
      askFor(profileUid, items, library: _library);

  /// [ask] 的不绑定 profile 形态（[profile] 为 null 时只能问不依赖 profile 的种类）。
  static List<Object?> askFor(
    String? profile,
    List<List<Object?>> items, {
    FushiFsrs? library,
  }) {
    if (items.isEmpty) return const <Object?>[];
    return _engine(library).deriveIds(profile, <List<Object?>>[
      for (final List<Object?> item in items)
        <Object?>[
          for (final Object? a in item) a is String ? _wellFormed(a) : a,
        ],
    ]);
  }

  List<String> _strings(List<List<Object?>> items) => ask(items).cast<String>();

  /// 笔记（由 guid）。
  String note(String guid) => notes(<String>[guid]).single;

  /// 批量 [note]（一次 FFI）。
  List<String> notes(List<String> guids) => _strings(<List<Object?>>[
    for (final String g in guids) <Object?>['note', g],
  ]);

  /// 笔记类型（由 ankiNum）。
  String noteType(int ankiNum) => _strings(<List<Object?>>[
    <Object?>['notetype', ankiNum],
  ]).single;

  /// 内置笔记类型（[key] = `lapis` / `fushi_card`）。
  String builtinNoteType(String key) => _strings(<List<Object?>>[
    <Object?>['builtin_notetype', key],
  ]).single;

  /// 牌组（由「父::子」全名）。同一全名已被别的牌组占着时用 [deckAlternate]。
  String deck(String fullPath) => _strings(<List<Object?>>[
    <Object?>['deck', fullPath],
  ]).single;

  /// 同一全名的第 [n] 个备选牌组 ID（n ≥ 1）。
  String deckAlternate(String fullPath, int n) => _strings(<List<Object?>>[
    <Object?>['deck_alt', fullPath, n],
  ]).single;

  /// [deck] 与前 [count] 个备选（n = 1…[count]），一次 FFI。
  List<String> deckCandidates(String fullPath, int count) =>
      _strings(<List<Object?>>[
        <Object?>['deck', fullPath],
        for (int n = 1; n <= count; n++) <Object?>['deck_alt', fullPath, n],
      ]);

  /// 内置默认牌组。
  String get defaultDeck => _strings(<List<Object?>>[
    const <Object?>['default_deck'],
  ]).single;

  /// 同步位置上这个 profile 的集合根目录名（`fushi-srs/<它>/`）。
  String get locationDir => _strings(<List<Object?>>[
    const <Object?>['location_dir'],
  ]).single;

  /// 「不合并笔记类型」导入时另建那一份的 ankiNum：由来源 ankiNum、是否填空与字段 / 模板身份确定性派生
  /// （两台设备导入同一个包得到同一个值）。再经 [noteType] 成为 ID。
  static int duplicateNoteTypeAnkiNum({
    required int sourceAnkiNum,
    required bool cloze,
    required List<SrsDupPart> fields,
    required List<SrsDupPart> templates,
    FushiFsrs? library,
  }) {
    List<Object?> parts(List<SrsDupPart> ps) => <Object?>[
      for (final SrsDupPart p in ps) <Object?>[p.configId, p.name],
    ];
    return askFor(null, <List<Object?>>[
          <Object?>[
            'dup_notetype_num',
            sourceAnkiNum,
            cloze,
            parts(fields),
            parts(templates),
          ],
        ], library: library).single!
        as int;
  }

  /// 旧并入（profile 合并）给还原不出派生输入的旧 ID 取的兜底 ID，并入目标是 [targetUid]（一次 FFI）。
  static List<String> mergeFallbacks(
    String targetUid,
    List<String> oldIds, {
    FushiFsrs? library,
  }) => askFor(null, <List<Object?>>[
    for (final String id in oldIds) <Object?>['merge_fallback', targetUid, id],
  ], library: library).cast<String>();

  /// 旧并入给最初的写入者 [origins] 改名用的哈希，并入目标是 [targetUid]（一次 FFI）。
  static List<String> mergedWriterHashes(
    String targetUid,
    List<String> origins, {
    FushiFsrs? library,
  }) => askFor(null, <List<Object?>>[
    for (final String o in origins) <Object?>['merged_writer', targetUid, o],
  ], library: library).cast<String>();
}
