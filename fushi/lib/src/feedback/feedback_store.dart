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
    this.fix,
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
    fix: FeedbackFix.tryParse(j['fix']),
  );

  /// 账户列表里、本机没有回执的条目（别的设备带账户提交的）：[ticket] 为空串，看详情
  /// 等操作走账户签名，补传附件不可用。
  factory FeedbackTicket.fromAccount(FeedbackSummary s) => FeedbackTicket(
    id: s.id,
    ticket: '',
    title: s.title,
    category: s.category,
    createdAt: s.createdAt,
    status: s.status,
    updatedAt: s.updatedAt,
    devReplyAt: s.devReplyAt,
    parentId: s.parentId,
  );

  final String id;

  /// 服务端只给一次的回执；空串 = 凭账户列出来的条目（见 [viaAccount]）。
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

  /// 本机没有回执、凭账户签名访问的条目（别的设备提交的）。
  bool get viaAccount => ticket.isEmpty;

  /// 最近一次拉到的修复与发布进度（列表据此显示「已修复」）；未标记修复为 null。
  final FeedbackFix? fix;

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
    fix: fix,
  );

  /// 用服务端摘要刷新进度（标题 / 状态 / 时刻 / 修复），本机字段（ticket / seenAt）不变。
  /// 修复以服务端为准：摘要里没有就清掉（开发者撤销了标记）。
  FeedbackTicket mergeSummary(FeedbackSummary s) => FeedbackTicket(
    id: id,
    ticket: ticket,
    title: s.title,
    category: category,
    createdAt: createdAt,
    status: s.status,
    updatedAt: s.updatedAt,
    devReplyAt: s.devReplyAt ?? devReplyAt,
    seenAt: seenAt,
    body: body,
    parentId: s.parentId ?? parentId,
    fix: s.fix,
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
    if (fix != null) 'fix': fix!.toJson(),
  };
}

/// 本机反馈清单文件。[fileName] 默认是本机回执清单 `tickets.json`；账户列表的缓存
/// （别的设备提交、凭账户签名看的那些，ticket 为空串）用 [FeedbackTicketStore.account]。
class FeedbackTicketStore {
  FeedbackTicketStore(this.supportRoot, {this.fileName = 'tickets.json'});

  /// 账户 [accountId] 的「我的反馈」缓存：只存进度与已读时刻，不含任何凭据。
  FeedbackTicketStore.account(this.supportRoot, String accountId)
    : fileName = 'account_${p.basename(accountId)}.json';

  final Directory supportRoot;
  final String fileName;

  File get file => File(p.join(supportRoot.path, 'feedback', fileName));

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

  /// 文件路径 → 该文件最后一次排队的写入。同一个文件的写入按调用顺序串行：临时文件名
  /// 固定（`<文件>.tmp`），并发的两次写会互相把对方的临时文件 rename 走，后一次 rename
  /// 就找不到源文件（打开详情时的「已读」落盘与「从本机移除」同时发生就会撞上）。
  static final Map<String, Future<void>> _writeTails = <String, Future<void>>{};

  /// 整份覆盖写入。同一文件的并发调用按调用顺序依次落盘，最后一次调用的内容为准。
  Future<void> write(List<FeedbackTicket> tickets) {
    final String key = file.path;
    final Future<void> previous = _writeTails[key] ?? Future<void>.value();
    final Future<void> next = previous
        .catchError((Object _) {})
        .then((_) => _writeNow(tickets));
    _writeTails[key] = next;
    return next.whenComplete(() {
      if (identical(_writeTails[key], next)) _writeTails.remove(key);
    });
  }

  Future<void> _writeNow(List<FeedbackTicket> tickets) async {
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

/// 提交时没传上去的附件（截图 / 日志 / 视频）：`<数据根>/feedback/pending/<id>/<slot>`。
/// 传成功或被服务端明确拒收后删除；随「从本机移除」一并清掉。视频（几十 MB）不读进内存，
/// 用 [fileOf] 拿文件流式上传；它的 MIME 记在同目录的 `<slot>.type` 旁注里。
class FeedbackPendingStore {
  FeedbackPendingStore(this.supportRoot);

  final Directory supportRoot;

  Directory get _root =>
      Directory(p.join(supportRoot.path, 'feedback', 'pending'));

  File _file(String id, String slot) =>
      File(p.join(_root.path, p.basename(id), p.basename(slot)));

  File _typeFile(String id, String slot) =>
      File('${_file(id, slot).path}.type');

  Future<void> put(String id, String slot, List<int> bytes) async {
    final File f = _file(id, slot);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  /// 把已经在磁盘上的文件挪进待传区（视频转码产物；跨卷挪不动时复制后删原件）。
  Future<File> putFile(
    String id,
    String slot,
    File source, {
    required String contentType,
  }) async {
    final File f = _file(id, slot);
    await f.parent.create(recursive: true);
    if (f.existsSync()) await f.delete();
    try {
      await source.rename(f.path);
    } on FileSystemException {
      await source.copy(f.path);
      try {
        await source.delete();
      } on FileSystemException {
        // 原件删不掉（用户自己的文件 / 只读）：不影响待传区那份。
      }
    }
    await _typeFile(id, slot).writeAsString(contentType, flush: true);
    return f;
  }

  Future<Uint8List?> read(String id, String slot) async {
    final File f = _file(id, slot);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  /// 待传文件与它的 MIME（没有返回 null）。
  Future<({File file, String contentType})?> fileOf(
    String id,
    String slot,
  ) async {
    final File f = _file(id, slot);
    if (!f.existsSync()) return null;
    final File type = _typeFile(id, slot);
    final String contentType = type.existsSync()
        ? (await type.readAsString()).trim()
        : 'application/octet-stream';
    return (file: f, contentType: contentType);
  }

  Future<void> remove(String id, String slot) async {
    final File f = _file(id, slot);
    if (f.existsSync()) await f.delete();
    final File type = _typeFile(id, slot);
    if (type.existsSync()) await type.delete();
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

  /// 扫描磁盘：反馈 id → 待传槽位（`.type` 旁注不算槽位）。
  Future<Map<String, Set<String>>> scan() async {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    if (!_root.existsSync()) return out;
    for (final FileSystemEntity d in _root.listSync()) {
      if (d is! Directory) continue;
      final Set<String> slots = <String>{
        for (final FileSystemEntity f in d.listSync())
          if (f is File && p.extension(f.path) != '.type') p.basename(f.path),
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
