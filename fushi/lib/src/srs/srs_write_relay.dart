/// 辅助进程的复习写入转交主进程（BUG-5542，拍板 D10「弹窗进程只读，弹窗里的制卡转交主进程」）。
///
/// 新代复习库只有主进程按 Primary 打开、是唯一的写者；Android `:popup` 查词窗与 `:second_screen` 面板按 Secondary
/// 只读打开（跨进程缓存与同设备双写由此免掉）。这些进程里制卡链的读照常在本进程做，**写**经这里交给主进程，在主进程
/// 自己的复习副本上执行，结果原样带回——提示与以前一样是那次写入的真实结果（成功 / 重复 / 失败，含覆写）。
///
/// - [RelaySrsNoteWriter]（辅助进程）：把一次写入打包成请求。制卡 / 覆写的请求用待发队列与互联转发同一个打包器
///   （[ForwardedMinePayloadBuilder]）冻结，媒体全读成字节写进双方都读得到的转交目录（请求本身只带文件路径：
///   Binder 一次事务装不下截图与音频）；连同本进程取定的配置副本（profile uid）、复习落点与 Anki 设置一起发出。
/// - [SrsWriteRelayHost]（主进程）：按请求里的配置副本与落点取主进程的制卡器，还原载荷（[withMaterializedMiningContext]）
///   后照本地制卡同一条路写，串行执行。
///
/// 传输（[SrsWriteRelayTransport]）由装配处注入：Android 上是 `srs_write_relay_channel.dart` 的 MethodChannel →
/// 原生 `SrsWriteRelayClient` → 主进程绑定的 `SrsWriteRelayService` → 主进程的执行引擎（主界面的引擎；主界面不在时
/// 由服务拉起一个无界面的执行引擎）。本文件不碰 Flutter，可纯 Dart 单测。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';

import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';
import 'package:fushi/src/srs/srs_generation_kind.dart';
import 'package:fushi/src/srs/srs_mining.dart';

/// 把一条请求交给主进程、等它的回包（JSON 对象）。传输本身失败（主进程起不来、中途死掉、超时）时抛。
typedef SrsWriteRelayTransport =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// 主进程按配置副本 uid 与落点取制卡器。复习不可用时 null；库在换代途中原样抛出代际异常（[SrsMinerResolver] 的契约）。
typedef SrsRelayMinerResolver =
    Future<SrsMiner?> Function(
      String profileUid,
      SrsMiningDestination destination,
    );

/// 请求 / 回包的键与命令名（两端同一份）。
abstract final class SrsWriteRelayWire {
  static const String op = 'op';
  static const String opMine = 'mine';
  static const String opOverwrite = 'overwrite';
  static const String opWriteFields = 'writeFields';
  static const String opDeleteNote = 'deleteNote';

  static const String profile = 'profile';
  static const String destination = 'destination';
  static const String settings = 'settings';
  static const String payloadPath = 'payloadPath';
  static const String noteId = 'noteId';
  static const String fields = 'fields';

  static const String outcome = 'outcome';
  static const String ok = 'ok';
  static const String error = 'error';
}

/// 主进程执行写入失败（改字段 / 删除这类不回 [MineOutcome] 的写）时，辅助进程抛给调用方的异常。
final class SrsWriteRelayException implements Exception {
  const SrsWriteRelayException(this.message);

  final String message;

  @override
  String toString() => 'SrsWriteRelayException: $message';
}

/// [SrsMiningDestination] ↔ JSON。
Map<String, Object?> encodeSrsMiningDestination(SrsMiningDestination d) =>
    <String, Object?>{
      'deckId': d.deckId,
      'noteTypeId': d.noteTypeId,
      'fieldMappingsByType': d.fieldMappingsByType,
    };

SrsMiningDestination decodeSrsMiningDestination(Object? json) {
  if (json is! Map) return const SrsMiningDestination();
  final Object? mappings = json['fieldMappingsByType'];
  return SrsMiningDestination(
    deckId: json['deckId'] as String? ?? '',
    noteTypeId: json['noteTypeId'] as String? ?? '',
    fieldMappingsByType: <String, Map<String, String>>{
      if (mappings is Map)
        for (final MapEntry<Object?, Object?> e in mappings.entries)
          if (e.key is String && e.value is Map)
            e.key! as String: <String, String>{
              for (final MapEntry<Object?, Object?> f
                  in (e.value! as Map).entries)
                if (f.key is String && f.value is String)
                  f.key! as String: f.value! as String,
            },
    },
  );
}

/// [MineOutcome] ↔ JSON。诊断（[MineOutcome.error] / [MineOutcome.stackTrace]）只能带文本过去：辅助进程据它记错误日志。
Map<String, Object?> encodeMineOutcome(MineOutcome o) => <String, Object?>{
  'result': o.result.name,
  if (o.noteId != null) 'noteId': o.noteId,
  if (o.deckName != null) 'deckName': o.deckName,
  if (o.audioWarning != null) 'audioWarning': o.audioWarning,
  if (o.notice != null) 'notice': o.notice,
  if (o.errorDetail != null) 'errorDetail': o.errorDetail,
  if (o.errorCode != null) 'errorCode': o.errorCode,
  if (o.error != null) 'error': '${o.error}',
  if (o.stackTrace != null) 'stack': '${o.stackTrace}',
};

MineOutcome decodeMineOutcome(Object? json) {
  if (json is! Map) {
    return MineOutcome.failure(
      'Fushi review: the main app sent back an unreadable result.',
    );
  }
  final String? deckName = json['deckName'] as String?;
  switch (json['result']) {
    case 'success':
      return MineOutcome.success(
        noteId: (json['noteId'] as num?)?.toInt(),
        deckName: deckName,
        audioWarning: json['audioWarning'] as String?,
        notice: json['notice'] as String?,
      );
    case 'duplicate':
      return const MineOutcome.duplicate();
    case 'notConfigured':
      return const MineOutcome.notConfigured();
    case 'queued':
      return MineOutcome.queued(deckName: deckName);
    default:
      final String? error = json['error'] as String?;
      final String? stack = json['stack'] as String?;
      return MineOutcome.failure(
        json['errorDetail'] as String? ??
            'Fushi review: the main app could not save the card.',
        errorCode: json['errorCode'] as String?,
        error: error == null ? null : StateError(error),
        stackTrace: stack == null ? null : StackTrace.fromString(stack),
      );
  }
}

/// 辅助进程的写入：一律转交主进程（见文件头）。
final class RelaySrsNoteWriter implements SrsNoteWriter {
  RelaySrsNoteWriter({
    required SrsWriteRelayTransport transport,
    required Future<Directory> Function() spoolDirectory,
    ForwardedMinePayloadBuilder? payloadBuilder,
  }) : _transport = transport,
       _spoolDirectory = spoolDirectory,
       _payloadBuilder = payloadBuilder ?? ForwardedMinePayloadBuilder();

  final SrsWriteRelayTransport _transport;

  /// 转交目录：两个进程都读得到（Android 上是 app 的 cache 目录下一层）。载荷文件由本端建、本端删。
  final Future<Directory> Function() _spoolDirectory;
  final ForwardedMinePayloadBuilder _payloadBuilder;

  static final Random _random = Random();

  @override
  Future<MineOutcome> mine(
    SrsMiner miner, {
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => _forwardMine(
    SrsWriteRelayWire.opMine,
    miner,
    settings: settings,
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<MineOutcome> overwrite(
    SrsMiner miner, {
    required String noteId,
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => _forwardMine(
    SrsWriteRelayWire.opOverwrite,
    miner,
    noteId: noteId,
    settings: settings,
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<void> writeFieldsByName(
    SrsMiner miner,
    String noteId,
    Map<String, String> fields,
  ) => _forwardWrite(<String, Object?>{
    ..._target(SrsWriteRelayWire.opWriteFields, miner),
    SrsWriteRelayWire.noteId: noteId,
    SrsWriteRelayWire.fields: fields,
  });

  @override
  Future<void> deleteNote(SrsMiner miner, String noteId) =>
      _forwardWrite(<String, Object?>{
        ..._target(SrsWriteRelayWire.opDeleteNote, miner),
        SrsWriteRelayWire.noteId: noteId,
      });

  /// 请求的公共部分：命令、配置副本、落点——主进程按这两样取它自己的制卡器。
  static Map<String, Object?> _target(String op, SrsMiner miner) =>
      <String, Object?>{
        SrsWriteRelayWire.op: op,
        SrsWriteRelayWire.profile: miner.store.profileUid,
        SrsWriteRelayWire.destination: encodeSrsMiningDestination(
          miner.destination,
        ),
      };

  /// 制卡 / 覆写：失败一律变成 [MineOutcome]（[SrsMiner.mine] 的契约，调用方按结果提示）。
  Future<MineOutcome> _forwardMine(
    String op,
    SrsMiner miner, {
    String? noteId,
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    File? spool;
    try {
      final ForwardedMinePayload payload = await _payloadBuilder.build(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
      spool = await _writeSpool(payload);
      final Map<String, Object?> reply = await _transport(<String, Object?>{
        ..._target(op, miner),
        if (noteId != null) SrsWriteRelayWire.noteId: noteId,
        SrsWriteRelayWire.settings: settings.toJson(),
        SrsWriteRelayWire.payloadPath: spool.path,
      });
      final Object? outcome = reply[SrsWriteRelayWire.outcome];
      if (outcome == null) {
        return MineOutcome.failure(
          'Fushi review: the main app could not save the card: '
          '${reply[SrsWriteRelayWire.error] ?? 'no result'}',
        );
      }
      return decodeMineOutcome(outcome);
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: could not hand the card to the main app: $e',
        error: e,
        stackTrace: stack,
      );
    } finally {
      await _deleteQuietly(spool);
    }
  }

  /// 改字段 / 删除：主进程报错时抛 [SrsWriteRelayException]（与本地写抛错同一个契约）。
  Future<void> _forwardWrite(Map<String, Object?> request) async {
    final Map<String, Object?> reply = await _transport(request);
    if (reply[SrsWriteRelayWire.ok] == true) return;
    throw SrsWriteRelayException(
      '${reply[SrsWriteRelayWire.error] ?? 'the main app did not confirm the write'}',
    );
  }

  Future<File> _writeSpool(ForwardedMinePayload payload) async {
    final Directory dir = await _spoolDirectory();
    await dir.create(recursive: true);
    final String name =
        'req_${DateTime.now().microsecondsSinceEpoch}_'
        '${_random.nextInt(1 << 32).toRadixString(16)}.json';
    final File file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(jsonEncode(payload.toJson()), flush: true);
    return file;
  }

  static Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      await file.delete();
    } on FileSystemException {
      // 已经不在：没有要删的。
    }
  }
}

/// 每次写入时再选执行方（[select] 现读）：装饰链可能在本进程知道自己是不是主进程之前就建好（查词窗的引擎预热时
/// provider 先于 `initialiseForDictionaryPopup` 建链），不能在建链那一刻取定。
final class SelectingSrsNoteWriter implements SrsNoteWriter {
  const SelectingSrsNoteWriter(this._select);

  final SrsNoteWriter Function() _select;

  @override
  Future<MineOutcome> mine(
    SrsMiner miner, {
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => _select().mine(
    miner,
    settings: settings,
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<MineOutcome> overwrite(
    SrsMiner miner, {
    required String noteId,
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => _select().overwrite(
    miner,
    noteId: noteId,
    settings: settings,
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<void> writeFieldsByName(
    SrsMiner miner,
    String noteId,
    Map<String, String> fields,
  ) => _select().writeFieldsByName(miner, noteId, fields);

  @override
  Future<void> deleteNote(SrsMiner miner, String noteId) =>
      _select().deleteNote(miner, noteId);
}

/// 主进程一端：执行辅助进程转交来的写入（见文件头）。请求串行执行（[drain] 等它们做完）。
final class SrsWriteRelayHost {
  SrsWriteRelayHost({
    required SrsRelayMinerResolver resolveMiner,
    void Function()? onWritten,
    SrsNoteWriter writer = const LocalSrsNoteWriter(),
  }) : _resolveMiner = resolveMiner,
       _onWritten = onWritten,
       _writer = writer;

  final SrsRelayMinerResolver _resolveMiner;

  /// 写成功之后调（装配处递增复习刷新信号：主界面的牌组列表 / 计数重读，本机推送照常触发）。
  final void Function()? _onWritten;
  final SrsNoteWriter _writer;
  final SerialJobQueue _queue = SerialJobQueue();

  static const String _unavailable = 'Fushi review is not available.';

  /// 执行一条请求，回包永不抛（传输层原样带回）。
  Future<Map<String, Object?>> handle(Map<String, Object?> request) =>
      _queue.enqueue<Map<String, Object?>>(
        () => _handle(request),
        buildFailure: (Object e, StackTrace stack) => <String, Object?>{
          SrsWriteRelayWire.error: '$e',
        },
      );

  /// 等已收下的请求全部执行完（交出主库之前）。
  Future<void> drain() => _queue.enqueue<void>(
    () async {},
    buildFailure: (Object e, StackTrace stack) {},
  );

  Future<Map<String, Object?>> _handle(Map<String, Object?> request) async {
    final Object? op = request[SrsWriteRelayWire.op];
    final Object? profile = request[SrsWriteRelayWire.profile];
    if (profile is! String || profile.isEmpty) {
      return <String, Object?>{SrsWriteRelayWire.error: 'missing profile'};
    }
    final SrsMiningDestination destination = decodeSrsMiningDestination(
      request[SrsWriteRelayWire.destination],
    );
    switch (op) {
      case SrsWriteRelayWire.opMine:
      case SrsWriteRelayWire.opOverwrite:
        return <String, Object?>{
          SrsWriteRelayWire.outcome: encodeMineOutcome(
            await _mineOrOverwrite(
              op as String,
              profile,
              destination,
              request,
            ),
          ),
        };
      case SrsWriteRelayWire.opWriteFields:
      case SrsWriteRelayWire.opDeleteNote:
        return _write(op as String, profile, destination, request);
      default:
        return <String, Object?>{SrsWriteRelayWire.error: 'unknown op $op'};
    }
  }

  Future<MineOutcome> _mineOrOverwrite(
    String op,
    String profile,
    SrsMiningDestination destination,
    Map<String, Object?> request,
  ) async {
    final SrsMiner? miner;
    try {
      miner = await _resolveMiner(profile, destination);
    } catch (e, stack) {
      // 主进程这边的库在换代途中：回带分类码的失败（提示「去复习页完成升级」），与本地制卡同一个答案（BUG-5085）。
      if (isSrsGenerationBlocked(e)) return srsGenerationMineFailure(e, stack);
      return MineOutcome.failure(
        'Fushi review: $e',
        error: e,
        stackTrace: stack,
      );
    }
    if (miner == null) return MineOutcome.failure(_unavailable);
    final Object? path = request[SrsWriteRelayWire.payloadPath];
    final Object? settingsJson = request[SrsWriteRelayWire.settings];
    if (path is! String || settingsJson is! Map) {
      return MineOutcome.failure('Fushi review: malformed card request.');
    }
    final ForwardedMinePayload payload;
    try {
      payload = ForwardedMinePayload.fromJson(
        (jsonDecode(await File(path).readAsString()) as Map)
            .cast<String, dynamic>(),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: could not read the card request: $e',
        error: e,
        stackTrace: stack,
      );
    }
    final AnkiSettings settings = AnkiSettings.fromJson(
      settingsJson.cast<String, dynamic>(),
    );
    final MineOutcome outcome =
        await withMaterializedMiningContext<MineOutcome>(payload, (
          String raw,
          AnkiMiningContext context,
        ) {
          if (op == SrsWriteRelayWire.opMine) {
            return _writer.mine(
              miner!,
              settings: settings,
              rawPayloadJson: raw,
              context: context,
            );
          }
          final Object? noteId = request[SrsWriteRelayWire.noteId];
          if (noteId is! String || noteId.isEmpty) {
            return Future<MineOutcome>.value(
              MineOutcome.failure('Fushi review: malformed card request.'),
            );
          }
          return _writer.overwrite(
            miner!,
            noteId: noteId,
            settings: settings,
            rawPayloadJson: raw,
            context: context,
          );
        });
    if (outcome.result == MineResult.success) _onWritten?.call();
    return outcome;
  }

  Future<Map<String, Object?>> _write(
    String op,
    String profile,
    SrsMiningDestination destination,
    Map<String, Object?> request,
  ) async {
    final Object? noteId = request[SrsWriteRelayWire.noteId];
    if (noteId is! String || noteId.isEmpty) {
      return <String, Object?>{SrsWriteRelayWire.error: 'missing noteId'};
    }
    final SrsMiner? miner = await _resolveMiner(profile, destination);
    if (miner == null) {
      return <String, Object?>{SrsWriteRelayWire.error: _unavailable};
    }
    if (op == SrsWriteRelayWire.opWriteFields) {
      final Object? fields = request[SrsWriteRelayWire.fields];
      if (fields is! Map) {
        return <String, Object?>{SrsWriteRelayWire.error: 'missing fields'};
      }
      await _writer.writeFieldsByName(miner, noteId, <String, String>{
        for (final MapEntry<Object?, Object?> e in fields.entries)
          '${e.key}': '${e.value}',
      });
    } else {
      await _writer.deleteNote(miner, noteId);
    }
    _onWritten?.call();
    return <String, Object?>{SrsWriteRelayWire.ok: true};
  }
}
