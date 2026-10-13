// 本机提交过的反馈清单（id + 回执 ticket + 最近一次拉到的进度）。
//
// ticket 是服务端只给一次的凭据：丢了就再也看不到那条反馈的进度，所以提交成功后
// 立刻落盘。文件是 `<数据根>/feedback/tickets.json`，与 Profile 无关（反馈是这台设备
// 发的，不是某个 Profile 的），写入走「临时文件 + rename」，权限尽量收成仅本人可读。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:path/path.dart' as p;

/// 一条本机反馈记录。
class FeedbackTicket {
  const FeedbackTicket({
    required this.id,
    required this.ticket,
    required this.title,
    required this.category,
    required this.createdAt,
    required this.status,
    required this.updatedAt,
    this.devReplyAt,
    this.seenAt = 0,
    this.missing = false,
    this.body = '',
    this.parentId,
  });

  factory FeedbackTicket.fromJson(Map<String, dynamic> j) => FeedbackTicket(
    id: j['id'] as String,
    ticket: j['ticket'] as String,
    title: j['title'] as String? ?? '',
    category: FeedbackCategory.fromWire(j['category']),
    createdAt: (j['createdAt'] as num).toInt(),
    status: FeedbackStatus.fromWire(j['status']),
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    devReplyAt: (j['devReplyAt'] as num?)?.toInt(),
    seenAt: (j['seenAt'] as num?)?.toInt() ?? 0,
    missing: j['missing'] == true,
    body: j['body'] as String? ?? '',
    parentId: j['parentId'] as String?,
  );

  final String id;
  final String ticket;
  final String title;
  final FeedbackCategory category;
  final int createdAt;
  final FeedbackStatus status;
  final int updatedAt;

  /// 开发者最近一次回复 / 改状态的时刻。
  final int? devReplyAt;

  /// 用户最近一次看过详情的时刻（服务端时刻口径）。
  final int seenAt;

  /// 服务端已查不到（ticket 不对 / 被清理）。保留条目让用户自己删。
  final bool missing;

  /// 正文（提交时 / 看详情时记下，「我的反馈」本机搜索用；旧记录可能为空）。
  final String body;

  /// 「问题没解决，重新提交」时指向的原反馈 id（本机列表据此显示两条的关联）。
  final String? parentId;

  /// 开发者有用户还没看过的新进展。
  bool get hasUnseenReply => devReplyAt != null && devReplyAt! > seenAt;

  FeedbackTicket copyWith({
    String? title,
    FeedbackStatus? status,
    int? updatedAt,
    int? devReplyAt,
    int? seenAt,
    bool? missing,
    String? body,
    String? parentId,
  }) => FeedbackTicket(
    id: id,
    ticket: ticket,
    title: title ?? this.title,
    category: category,
    createdAt: createdAt,
    status: status ?? this.status,
    updatedAt: updatedAt ?? this.updatedAt,
    devReplyAt: devReplyAt ?? this.devReplyAt,
    seenAt: seenAt ?? this.seenAt,
    missing: missing ?? this.missing,
    body: body ?? this.body,
    parentId: parentId ?? this.parentId,
  );

  /// 用服务端摘要刷新进度（标题 / 状态 / 时刻），本机字段（ticket / seenAt）不变。
  FeedbackTicket mergeSummary(FeedbackSummary s) => copyWith(
    title: s.title,
    status: s.status,
    updatedAt: s.updatedAt,
    devReplyAt: s.devReplyAt,
    missing: false,
    parentId: s.parentId,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'ticket': ticket,
    'title': title,
    'category': category.wire,
    'createdAt': createdAt,
    'status': status.wire,
    'updatedAt': updatedAt,
    if (devReplyAt != null) 'devReplyAt': devReplyAt,
    'seenAt': seenAt,
    if (missing) 'missing': true,
    if (body.isNotEmpty) 'body': body,
    if (parentId != null) 'parentId': parentId,
  };
}

/// 本机反馈清单文件。
class FeedbackTicketStore {
  FeedbackTicketStore(this.supportRoot);

  final Directory supportRoot;

  File get file => File(p.join(supportRoot.path, 'feedback', 'tickets.json'));

  /// 读全部记录（新的在前）。文件不存在 / 损坏返回空清单（损坏的原文件改名留档，不覆盖）。
  Future<List<FeedbackTicket>> read() async {
    final File f = file;
    if (!f.existsSync()) return <FeedbackTicket>[];
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      final List<Object?> items =
          (decoded as Map<Object?, Object?>)['items'] as List<Object?>? ??
          const <Object?>[];
      final List<FeedbackTicket> out = <FeedbackTicket>[
        for (final Object? e in items)
          FeedbackTicket.fromJson(
            (e as Map<Object?, Object?>).cast<String, dynamic>(),
          ),
      ];
      out.sort(
        (FeedbackTicket a, FeedbackTicket b) =>
            b.createdAt.compareTo(a.createdAt),
      );
      return out;
    } on Object {
      final String backup =
          '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      try {
        await f.rename(backup);
      } on FileSystemException {
        // 改名失败就留着原文件；下一次写入会覆盖它。
      }
      return <FeedbackTicket>[];
    }
  }

  Future<void> write(List<FeedbackTicket> tickets) async {
    final File f = file;
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'items': <Map<String, dynamic>>[
          for (final FeedbackTicket t in tickets) t.toJson(),
        ],
      }),
      flush: true,
    );
    await _restrictToOwner(tmp.path);
    await tmp.rename(f.path);
  }

  // 与 LeaderboardStore 同一口径：Windows 靠 app 私有目录 + NTFS ACL；移动端应用数据
  // 目录本就只有本 app 可读，且沙箱里起不了子进程。
  static Future<void> _restrictToOwner(String path) async {
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
    try {
      await Process.run('chmod', <String>['600', path]);
    } on ProcessException {
      // 没有 chmod（非 POSIX 环境）：文件仍在 app 私有目录里，不阻断功能。
    }
  }
}

/// 提交时没传上去的附件（截图 / 日志）的字节：`<数据根>/feedback/pending/<id>/<slot>`。
/// 传成功或被服务端明确拒收后删除；随「从本机移除」一并清掉。
class FeedbackPendingStore {
  FeedbackPendingStore(this.supportRoot);

  final Directory supportRoot;

  Directory get _root =>
      Directory(p.join(supportRoot.path, 'feedback', 'pending'));

  File _file(String id, String slot) =>
      File(p.join(_root.path, p.basename(id), p.basename(slot)));

  Future<void> put(String id, String slot, List<int> bytes) async {
    final File f = _file(id, slot);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> read(String id, String slot) async {
    final File f = _file(id, slot);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  Future<void> remove(String id, String slot) async {
    final File f = _file(id, slot);
    if (f.existsSync()) await f.delete();
    final Directory dir = f.parent;
    if (!dir.existsSync() || dir.listSync().isNotEmpty) return;
    try {
      await dir.delete();
    } on FileSystemException {
      // 查空与删除之间被并发的 [put] 写进了新槽位（非递归删除遇非空目录失败），或目录
      // 已被别人删掉：两种情况目录此刻都不该再删。只有它仍在、仍然空却删不掉才是真错误。
      if (dir.existsSync() && dir.listSync().isEmpty) rethrow;
    }
  }

  Future<void> removeAll(String id) async {
    final Directory dir = Directory(p.join(_root.path, p.basename(id)));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 扫描磁盘：反馈 id → 待传槽位。
  Future<Map<String, Set<String>>> scan() async {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    if (!_root.existsSync()) return out;
    for (final FileSystemEntity d in _root.listSync()) {
      if (d is! Directory) continue;
      final Set<String> slots = <String>{
        for (final FileSystemEntity f in d.listSync())
          if (f is File) p.basename(f.path),
      };
      if (slots.isNotEmpty) out[p.basename(d.path)] = slots;
    }
    return out;
  }
}

/// 上次提交填的联系方式：`<数据根>/feedback/last_contact.txt`。独立于草稿目录（清草稿
/// 不会带走它），也不走草稿仓库的串行队列（读它不该排在草稿读写后面）。
class FeedbackContactStore {
  FeedbackContactStore(this.supportRoot);

  final Directory supportRoot;

  File get file =>
      File(p.join(supportRoot.path, 'feedback', 'last_contact.txt'));

  /// 没有记录返回空串。
  Future<String> read() async {
    final File f = file;
    return f.existsSync() ? (await f.readAsString()).trim() : '';
  }

  Future<void> write(String contact) async {
    final File f = file;
    await f.parent.create(recursive: true);
    await f.writeAsString(contact, flush: true);
  }
}
