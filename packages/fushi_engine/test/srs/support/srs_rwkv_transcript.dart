// RWKV 排程编排的对拍记录（srs_rwkv_service_test.dart 用）。
//
// 把一条用例里「编排对外做了什么」记成与运行无关的规范形，和入库的夹具
// `fixtures/srs_rwkv_orchestration.json` 逐值比较：
//   - backends：每个替身后端收到的调用序列（操作、行、标签、时刻、参数、返回值）；
//   - store：编排向复习库发的三条取数命令（rwkvLogTail / rwkvReplay / rwkvCardRows）的参数与结果摘要；
//   - status：每个服务的状态事件序列；
//   - scores：排队 / 统计两个打分入口的参数与返回值；
//   - files：用例结束时快照目录里的文件与元数据。
// 各通道内部有序，通道之间的先后不比（并发操作的交错不属于契约）。
//
// 夹具由搬进 Rust 内核之前的 Dart 编排生成（docs/specs 见 PR 描述）；之后的实现必须在同样的场景下产出
// 同样的记录。只在有意改变编排语义时重写：`SRS_RWKV_TRANSCRIPTS_WRITE=1` 跑 srs_rwkv_service_test.dart。
//
// 不冻结的用例：两次写入（作答 / 撤销）之间不等对齐的用例，后台对齐（`onAnswered`）与下一次写入的先后取决于
// 调度，同一批日志可能分一次或两次追加，结果相同、调用粒度不同。这类用例标 [SrsRwkvTranscript.unstable]，
// 夹具里只留原因。排查有没有漏标：`SRS_RWKV_TRANSCRIPTS_JITTER=<种子>` 给编排的取数加随机延迟，连同写模式
// 跑几遍，生成的夹具应当逐字节相同。
//
// 规范形：卡的数字 id → `c<创建序号>`（没登记过的 `x<首次出现序号>`）；撤销日志标签 → `t<首次出现序号>`；
// 分数表版本 → `v<该卡的第几个版本>`；毫秒时刻 → 相对用例起始时钟的偏移；路径 → 文件名。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String kSrsRwkvTranscriptFixture =
    'test/srs/fixtures/srs_rwkv_orchestration.json';

/// 一条用例的记录。
class SrsRwkvTranscript {
  SrsRwkvTranscript(this.baseMs);

  /// 用例起始时钟：时刻都记成相对它的偏移。
  final int baseMs;

  final Map<int, String> _cards = <int, String>{};
  final Map<int, int> _order = <int, int>{};
  final Map<String, String> _cardOfId = <String, String>{};
  final Map<int, String> _tags = <int, String>{};
  final Map<String, Map<int, String>> _versions = <String, Map<int, String>>{};
  int _strangers = 0;
  int _created = 0;

  final List<List<Object?>> _backends = <List<Object?>>[];
  final List<List<Object?>> _stores = <List<Object?>>[];
  final List<List<Object?>> _status = <List<Object?>>[];
  final List<List<Object?>> _scores = <List<Object?>>[];
  final List<Directory> _snapshotDirs = <Directory>[];

  /// 记录过的事件总数（收尾时等它不再增长）。
  int events = 0;

  /// 这条用例的记录不冻结的原因（见文件头）；null = 冻结。
  String? unstableReason;

  /// 标成不冻结：调用序列取决于调度，夹具里只留 [reason]。
  void unstable(String reason) => unstableReason = reason;

  /// 登记一张卡（按创建顺序命名）。
  void registerCard(String cardId) {
    final String name = 'c${_created++}';
    final int numericId = SrsIds.ankiNumericIds(<String>[cardId]).single;
    _order[numericId] = _created - 1;
    _cards[numericId] = name;
    _cardOfId[cardId] = name;
  }

  String card(int numericId) =>
      _cards.putIfAbsent(numericId, () => 'x${_strangers++}');

  /// 卡的创建序号（[registerCard] 的顺序）；没登记过的是 null。
  int? creationOrder(int numericId) => _order[numericId];

  String cardOfId(String cardId) =>
      _cardOfId[cardId] ?? card(SrsIds.ankiNumericIds(<String>[cardId]).single);

  String tag(int value) => _tags.putIfAbsent(value, () => 't${_tags.length}');

  String version(String card, int value) {
    final Map<int, String> seen = _versions.putIfAbsent(
      card,
      () => <int, String>{},
    );
    return seen.putIfAbsent(value, () => 'v${seen.length}');
  }

  /// 毫秒时刻 → 相对偏移；哨兵值按名字记。
  Object? time(int? ms) {
    if (ms == null) return null;
    if (ms == kRwkvFloorEmpty) return 'empty';
    if (ms == kRwkvFloorUnknown) return 'unknown';
    return ms - baseMs;
  }

  /// 新开一个后端通道，返回它的事件表。
  List<Object?> openBackend() {
    final List<Object?> channel = <Object?>[];
    _backends.add(channel);
    return channel;
  }

  /// 新开一个服务（store 取数 / 状态 / 打分三个通道）。
  ({List<Object?> store, List<Object?> status, List<Object?> scores})
  openService(Directory snapshotDir) {
    final List<Object?> store = <Object?>[];
    final List<Object?> status = <Object?>[];
    final List<Object?> scores = <Object?>[];
    _stores.add(store);
    _status.add(status);
    _scores.add(scores);
    if (!_snapshotDirs.any((Directory d) => d.path == snapshotDir.path)) {
      _snapshotDirs.add(snapshotDir);
    }
    return (store: store, status: status, scores: scores);
  }

  /// 一行回放 / 查询行：卡、评分、调度日、间隔天 / 秒、card_type（没有的字段是 null）。
  List<Object?> row(RwkvRows rows, int i) {
    final ByteData d = ByteData.sublistView(rows.bytes);
    final int at = i * kFrwkvReviewSize;
    final int present = d.getUint32(at + 72, Endian.little);
    int? field(int index, int bit) =>
        present & bit == 0 ? null : d.getInt64(at + 8 * index, Endian.little);
    return <Object?>[
      card(rows.cardIdAt(i)),
      rows.easeAt(i),
      field(6, FrwkvPresent.dayOffset),
      field(7, FrwkvPresent.elapsedDays),
      field(8, FrwkvPresent.elapsedSeconds),
      field(5, FrwkvPresent.cardType),
    ];
  }

  List<Object?> rowList(RwkvRows rows) => <Object?>[
    for (int i = 0; i < rows.length; i++) row(rows, i),
  ];

  /// 与顺序无关的一批行（查询 / 分数表更新：候选卡的顺序取决于随机 UUID）：按卡名排序。
  List<Object?> sortedByCard(List<List<Object?>> entries) => entries
    ..sort(
      (List<Object?> a, List<Object?> b) =>
          (a.first! as String).compareTo(b.first! as String),
    );

  Future<Map<String, Object?>> toJson() async => <String, Object?>{
    'backends': _backends,
    'store': _stores,
    'status': _status,
    'scores': _scores,
    'files': <Object?>[
      for (final Directory d in _snapshotDirs) await _files(d),
    ],
  };

  Future<List<Object?>> _files(Directory dir) async {
    if (!dir.existsSync()) return const <Object?>[];
    final List<File> files = dir.listSync().whereType<File>().toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    return <Object?>[
      for (final File f in files)
        <Object?>[
          p.basename(f.path),
          if (f.path.endsWith('.json'))
            _tryJson(f.readAsStringSync())
          else
            _snapshotCards(f),
        ],
    ];
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  /// 替身后端的快照 = 已回放的卡（数字 id 的 JSON 数组）；别的内容（测试写坏的文件）原样记。
  Object? _snapshotCards(File f) {
    final String text = f.readAsStringSync();
    final Object? decoded = _tryJson(text);
    if (decoded is List && decoded.every((Object? e) => e is int)) {
      return <Object?>[for (final Object? e in decoded) card(e! as int)];
    }
    return text;
  }
}

/// 把 [inner] 套一层：三条取数命令记进 [log]，编排用到的其余成员原样转发。
///
/// `SrsDbStore` 是具体类、没有可继承的构造函数，所以按接口实现并逐个转发编排用到的成员；
/// 编排碰了别的成员会落到 [noSuchMethod] 直接失败（那时在这里补转发）。
class SrsRwkvRecordingStore implements SrsDbStore {
  SrsRwkvRecordingStore(this._inner, this._t, this._log);

  final SrsDbStore _inner;
  final SrsRwkvTranscript _t;
  final List<Object?> _log;

  /// 排查不稳定的记录用（文件头）：每次取数前随机等 0～3 ms。
  static final Random? _jitter = switch (int.tryParse(
    Platform.environment['SRS_RWKV_TRANSCRIPTS_JITTER'] ?? '',
  )) {
    final int seed => Random(seed),
    null => null,
  };

  Future<void> _delay() async {
    final Random? r = _jitter;
    if (r == null) return;
    await Future<void>.delayed(Duration(milliseconds: r.nextInt(4)));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'SrsRwkvRecordingStore does not forward ${invocation.memberName}',
  );

  @override
  String get profileUid => _inner.profileUid;
  @override
  String get defaultDeckId => _inner.defaultDeckId;
  @override
  String get contentFingerprint => _inner.contentFingerprint;
  @override
  Future<String> changeFingerprint() async {
    await _delay();
    return _inner.changeFingerprint();
  }

  @override
  String get rwkvScoresKey => _inner.rwkvScoresKey;
  @override
  String get rwkvScoresClearKey => _inner.rwkvScoresClearKey;
  @override
  bool get sync2Ingesting => _inner.sync2Ingesting;
  @override
  Future<void> sync2IngestSettled() => _inner.sync2IngestSettled();
  @override
  Future<SrsDayContext> dayContext() => _inner.dayContext();
  @override
  Future<SrsDeckTree> deckTree() => _inner.deckTree();
  @override
  Future<SrsCardCacheRow?> cardRow(String cardId) => _inner.cardRow(cardId);
  @override
  Future<SrsColumns> cardColumns({
    List<String>? fields,
    bool visibleOnly = false,
  }) => _inner.cardColumns(fields: fields, visibleOnly: visibleOnly);

  @override
  Future<SrsRwkvLogTail> rwkvLogTail({
    required int since,
    bool withRows = false,
    bool incremental = false,
  }) async {
    await _delay();
    final SrsRwkvLogTail t = await _inner.rwkvLogTail(
      since: since,
      withRows: withRows,
      incremental: incremental,
    );
    _t.events++;
    _log.add(<Object?>[
      'tail',
      <String, Object?>{
        'since': since,
        'withRows': withRows,
        'incremental': incremental,
      },
      <String, Object?>{
        'count': t.count,
        'maxRowId': t.maxRowId,
        'newRows': t.newRows,
        'logs': <Object?>[
          for (final SrsRwkvTailLog l in t.logs)
            <Object?>[
              l.kind,
              _t.cardOfId(l.cardId),
              _t.time(l.at),
              l.revokes != null,
            ],
        ],
      },
    ]);
    return t;
  }

  @override
  Future<SrsRwkvReplay> rwkvReplay(
    List<String> cardIds,
    List<int> ids,
    SrsDayContext day, {
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) async {
    await _delay();
    final SrsRwkvReplay r = await _inner.rwkvReplay(
      cardIds,
      ids,
      day,
      since: since,
      rebaseSince: rebaseSince,
      rowsFrom: rowsFrom,
    );
    _t.events++;
    _log.add(<Object?>[
      'replay',
      <String, Object?>{
        'cards': cardIds.length,
        'since': since,
        'rebaseSince': rebaseSince,
        'rowsFrom': _t.time(rowsFrom),
      },
      <String, Object?>{
        'count': r.count,
        'maxRowId': r.maxRowId,
        'lastAt': _t.time(r.lastAt),
        'rows': _t.rowList(r.rows),
        'ats': <Object?>[for (final int at in r.ats) _t.time(at)],
        'strays': r.strays.length,
        'divergeAt': _t.time(r.divergeAt),
        'tailRows': r.tailRows,
      },
    ]);
    return r;
  }

  @override
  Future<List<SrsRwkvCardRows>> rwkvCardRows(
    List<String> cardIds,
    List<int> ids,
    SrsDayContext day,
  ) async {
    await _delay();
    final List<SrsRwkvCardRows> out = await _inner.rwkvCardRows(
      cardIds,
      ids,
      day,
    );
    _t.events++;
    _log.add(<Object?>[
      'cards',
      _t.sortedByCard(<List<Object?>>[
        for (int i = 0; i < cardIds.length; i++)
          <Object?>[
            _t.cardOfId(cardIds[i]),
            out[i].keptIds.length,
            out[i].effectiveRatings,
            _t.time(out[i].last?.at),
          ],
      ]),
    ]);
    return out;
  }
}

/// 用例结束时：把 [transcript] 与夹具里 [test] 这条用例的记录比较（或在写模式下收集起来）。
/// 一条用例里有多份记录（多个夹具）时按收尾顺序编号（`名字 #2`…）。
Future<void> srsRwkvCheckTranscript(
  String test,
  SrsRwkvTranscript transcript,
) async {
  final String? unstable = transcript.unstableReason;
  final Map<String, Object?> actual = unstable != null
      ? <String, Object?>{'unstable': unstable}
      : jsonDecode(jsonEncode(await transcript.toJson()))
            as Map<String, Object?>;
  final int nth = _checked[test] = (_checked[test] ?? 0) + 1;
  final String name = nth == 1 ? test : '$test #$nth';
  if (_writing) {
    _written[name] = actual;
    return;
  }
  final Map<String, Object?> all = _fixture();
  final Object? expected = all[name];
  if (expected == null) {
    fail(
      'no orchestration transcript recorded for "$name"; '
      'run with SRS_RWKV_TRANSCRIPTS_WRITE=1 only if the scenario is new',
    );
  }
  expect(
    actual,
    expected,
    reason:
        'RWKV orchestration transcript differs from the frozen one for "$name"',
  );
}

final bool _writing = Platform.environment['SRS_RWKV_TRANSCRIPTS_WRITE'] == '1';
final Map<String, Object?> _written = <String, Object?>{};
final Map<String, int> _checked = <String, int>{};
Map<String, Object?>? _loaded;

File _fixtureFile() =>
    File('${Directory.current.path}/$kSrsRwkvTranscriptFixture');

Map<String, Object?> _fixture() => _loaded ??=
    jsonDecode(_fixtureFile().readAsStringSync()) as Map<String, Object?>;

/// 写模式下把收集到的记录落盘（`tearDownAll` 里调）；键按名字排序，文本稳定。
void srsRwkvWriteTranscripts() {
  if (!_writing) return;
  final List<String> names = _written.keys.toList()..sort();
  final StringBuffer out = StringBuffer('{\n');
  for (int i = 0; i < names.length; i++) {
    out
      ..write('  ${jsonEncode(names[i])}: ')
      ..write(_pretty(_written[names[i]], 1))
      ..write(i + 1 == names.length ? '\n' : ',\n');
  }
  out.write('}\n');
  _fixtureFile().writeAsStringSync(out.toString());
}

/// 两层以内展开成多行，更深的写成一行：每条事件一行，夹具的 diff 看得出是哪一步变了。
String _pretty(Object? value, int depth) {
  final String pad = '  ' * (depth + 1);
  final String close = '  ' * depth;
  if (value is Map<String, Object?> && depth <= 1) {
    if (value.isEmpty) return '{}';
    final List<String> keys = value.keys.toList();
    return '{\n${<String>[for (final String k in keys) '$pad${jsonEncode(k)}: ${_pretty(value[k], depth + 1)}'].join(',\n')}\n$close}';
  }
  if (value is List<Object?> && depth <= 3) {
    if (value.isEmpty) return '[]';
    return '[\n${<String>[for (final Object? v in value) '$pad${_pretty(v, depth + 1)}'].join(',\n')}\n$close]';
  }
  return jsonEncode(value);
}
