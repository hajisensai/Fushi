import 'dart:async';
import 'dart:isolate';

import 'package:drift/isolate.dart' show DriftIsolate;
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';

/// 后台所有者 isolate 的调试名（测试据此确认命令确实不在调用方执行）。
const String kAggregateSyncOwnerDebugName = 'aggregate-sync-owner';

/// 仅供测试：为 true 时 [AggregateSyncOwner.spawn] 不起 isolate，命令直接在调用方
/// isolate 里用调用方的库连接执行。
///
/// 只给 `testWidgets` 这类跑在 FakeAsync 里的界面测试用：那里真实的跨 isolate 消息
/// 往返推不动（一轮同步有上百次往返），被测的是界面行为而不是执行位置。执行位置由
/// `aggregate_sync_off_ui_isolate_test.dart` 用真后台所有者钉住。生产代码从不设置。
@visibleForTesting
bool debugAggregateSyncOwnerInline = false;

/// 发给 [AggregateSyncOwner] 的一条命令：在后台 isolate 里拿
/// [AggregateOwnerContext] 执行，只把**轻量结果**（布尔、计数、哈希、报文体字节）
/// 交回调用方。
///
/// 命令以闭包形式发送：闭包只能引用可跨 isolate 发送的数据（参数、字节），不得捕获
/// 调用方持有数据库连接的对象——写成 static 方法里构造的闭包，作用域里没有 `this`。
typedef AggregateOwnerCommand<R> =
    FutureOr<R> Function(AggregateOwnerContext context);

/// 后台所有者 isolate 内的状态：它自己那条库连接，加上一轮同步跨命令暂存的数据。
final class AggregateOwnerContext {
  AggregateOwnerContext(this.db);

  /// 经 [FushiDatabase.backgroundConnection] 接上的同一个库（同一个 drift 服务端、
  /// 同一把 sqlite 连接），读写都不经调用方 isolate。
  final FushiDatabase db;

  /// 一轮同步里命令之间暂存的整份数据（本地快照、合并结果等）。只活在后台 isolate，
  /// 从不回传；由发命令的一方自己定义类型。
  Object? session;
}

/// 聚合同步（统计 / 收藏 / 浏览历史快照）的**后台所有者**（HBK-AUDIT-028）。
///
/// 一轮同步（或 host 的一次 GET / PUT）开一个所有者 isolate：它用
/// [FushiDatabase.backgroundConnection] 接上同一个库，DB 读取 + 快照组装 + 墓碑裁剪 +
/// 折叠 + 差集 + 写回 + 报文体编解码都在它里面做，整份快照从头到尾只活在这一个
/// isolate 里；调用方只发命令、收轻量结果。命令按到达顺序逐条执行（同一轮的各步
/// 天然串行）。
///
/// 互联 host 的合集 / 标签 / 作品图谱清单端点也借它在后台现算与编解码
/// （`host_manifest_bodies.dart`，BUG-5606）：命令形状相同，与聚合同步无关的只是
/// 命令内容。
///
/// 为什么是「每轮一个」而不是全进程常驻一个：聚合同步是低频的整轮操作，单轮内的
/// 状态（本地快照、合并结果）本来就只在这一轮有效；常驻要额外管理与库连接同生共死、
/// 库关闭 / 热重启 / 多个库实例时的回收，换来的只是省掉一次 isolate 启动（同组
/// spawn 毫秒级，且不阻塞调用方）。
final class AggregateSyncOwner {
  AggregateSyncOwner._(this._isolate, this._replies, this._exit)
    : _inline = null;

  AggregateSyncOwner._inline(FushiDatabase db)
    : _isolate = null,
      _replies = null,
      _exit = null,
      _inline = AggregateOwnerContext(db);

  final Isolate? _isolate;
  final ReceivePort? _replies;
  final ReceivePort? _exit;

  /// [debugAggregateSyncOwnerInline] 模式下的上下文（命令在调用方执行）。
  final AggregateOwnerContext? _inline;
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Completer<void> _exited = Completer<void>();
  SendPort? _commands;
  int _nextId = 0;
  bool _closing = false;

  /// 为 [db] 起一个后台所有者。用完必须 [close]（放在 finally 里）。
  static Future<AggregateSyncOwner> spawn(FushiDatabase db) async {
    if (debugAggregateSyncOwnerInline) return AggregateSyncOwner._inline(db);
    final DriftIsolate connection = await db.backgroundConnection();
    final ReceivePort replies = ReceivePort(
      '$kAggregateSyncOwnerDebugName/replies',
    );
    final ReceivePort exit = ReceivePort('$kAggregateSyncOwnerDebugName/exit');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<(SendPort, DriftIsolate)>(
        _ownerMain,
        (replies.sendPort, connection),
        debugName: kAggregateSyncOwnerDebugName,
        onExit: exit.sendPort,
      );
    } catch (_) {
      replies.close();
      exit.close();
      rethrow;
    }
    final AggregateSyncOwner owner = AggregateSyncOwner._(
      isolate,
      replies,
      exit,
    );
    replies.listen(owner._onReply);
    exit.listen((Object? _) => owner._onExit());
    owner._commands = await owner._ready.future;
    return owner;
  }

  /// 在所有者 isolate 里执行 [command]，返回它的结果。命令抛的异常原样（类型不变）
  /// 在这里重新抛出，栈是所有者 isolate 里的栈。
  Future<R> run<R>(AggregateOwnerCommand<R> command) async {
    final AggregateOwnerContext? inline = _inline;
    if (inline != null) {
      if (_closing) throw StateError('AggregateSyncOwner is closed');
      return await command(inline);
    }
    final SendPort? commands = _commands;
    if (commands == null || _closing || _exited.isCompleted) {
      throw StateError('AggregateSyncOwner is closed');
    }
    final int id = _nextId++;
    final Completer<Object?> reply = Completer<Object?>();
    _pending[id] = reply;
    commands.send((id, command));
    return (await reply.future) as R;
  }

  /// 让所有者关掉自己的库连接并退出，等它真正退出再返回。幂等。
  Future<void> close() async {
    if (_inline != null) {
      _closing = true;
      return;
    }
    if (!_closing) {
      _closing = true;
      if (_commands != null && !_exited.isCompleted) _commands!.send(null);
    }
    await _exited.future;
  }

  void _onReply(Object? message) {
    if (message is SendPort) {
      _ready.complete(message);
      return;
    }
    final (int id, bool ok, Object? value, String? stack) =
        message! as (int, bool, Object?, String?);
    if (id < 0) {
      // 启动失败（接不上库）：所有者已自行退出。
      _ready.completeError(value!, StackTrace.fromString(stack ?? ''));
      return;
    }
    final Completer<Object?>? reply = _pending.remove(id);
    if (reply == null) return;
    if (ok) {
      reply.complete(value);
    } else {
      reply.completeError(value!, StackTrace.fromString(stack ?? ''));
    }
  }

  void _onExit() {
    _replies!.close();
    _exit!.close();
    final StateError gone = StateError(
      'AggregateSyncOwner isolate exited unexpectedly',
    );
    if (!_ready.isCompleted) _ready.completeError(gone);
    for (final Completer<Object?> reply in _pending.values) {
      reply.completeError(gone);
    }
    _pending.clear();
    if (!_exited.isCompleted) _exited.complete();
  }

  /// 仅供测试：所有者 isolate 的句柄（inline 模式为 null）。
  @visibleForTesting
  Isolate? get isolateForTesting => _isolate;
}

Future<void> _ownerMain((SendPort, DriftIsolate) args) async {
  final (SendPort replies, DriftIsolate connection) = args;
  final FushiDatabase db;
  try {
    db = FushiDatabase.shared(await connection.connect());
  } catch (e, stack) {
    _sendReply(replies, -1, false, e, stack);
    return;
  }
  final ReceivePort commands = ReceivePort(
    '$kAggregateSyncOwnerDebugName/commands',
  );
  final AggregateOwnerContext context = AggregateOwnerContext(db);
  replies.send(commands.sendPort);
  try {
    await for (final Object? message in commands) {
      if (message == null) break; // close()
      final (int id, AggregateOwnerCommand<Object?> command) =
          message as (int, AggregateOwnerCommand<Object?>);
      try {
        _sendReply(replies, id, true, await command(context), null);
      } catch (e, stack) {
        _sendReply(replies, id, false, e, stack);
      }
    }
  } finally {
    commands.close();
    context.session = null;
    await db.close();
  }
}

/// 发一条回复。异常对象发不过去（持有不可发送的资源）时退成 [RemoteError]，
/// 保住「调用方一定收到回复」，不让这条命令永远挂起。
void _sendReply(
  SendPort replies,
  int id,
  bool ok,
  Object? value,
  StackTrace? stack,
) {
  try {
    replies.send((id, ok, value, stack?.toString()));
  } catch (_) {
    if (ok) rethrow; // 命令结果必须可发送：这是调用方代码的 bug，不掩盖。
    replies.send((
      id,
      false,
      RemoteError(value.toString(), stack?.toString() ?? ''),
      stack?.toString(),
    ));
  }
}
