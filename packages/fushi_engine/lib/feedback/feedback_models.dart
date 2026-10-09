// 用户反馈的 JSON 线格式（真相源：services/leaderboard/src/feedback.js）。
//
// 只做 fromJson/toJson 的忠实映射。提交侧的上限与服务端 FEEDBACK_LIMITS 一致，
// 在本机先拦住服务端必然 400 / 413 的形状。

typedef FeedbackJson = Map<String, dynamic>;

int _int(Object? v) => (v as num).toInt();
int? _intOrNull(Object? v) => v == null ? null : (v as num).toInt();
String _str(Object? v) => v as String? ?? '';
FeedbackJson _map(Object? v) =>
    (v as Map<Object?, Object?>).cast<String, dynamic>();
List<T> _list<T>(Object? v, T Function(FeedbackJson) f) => List<T>.unmodifiable(
  ((v as List<Object?>?) ?? const <Object?>[]).map((Object? e) => f(_map(e))),
);

/// 与服务端 FEEDBACK_LIMITS 对齐。
abstract final class FeedbackLimits {
  static const int titleMax = 120;
  static const int bodyMax = 8000;
  static const int contactMax = 200;
  static const int replyMax = 4000;
  static const int screenshots = 3;
  static const int screenshotMaxBytes = 1536 * 1024;
  static const int logMaxBytes = 2 * 1024 * 1024;
  static const int statusBatch = 50;
}

enum FeedbackCategory {
  bug('bug'),
  suggestion('suggestion'),
  other('other');

  const FeedbackCategory(this.wire);
  final String wire;

  static FeedbackCategory fromWire(Object? raw) => FeedbackCategory.values
      .firstWhere((FeedbackCategory c) => c.wire == raw, orElse: () => other);
}

enum FeedbackStatus {
  open('open'),
  inProgress('in_progress'),
  resolved('resolved'),
  wontFix('wont_fix'),
  duplicate('duplicate'),
  closed('closed');

  const FeedbackStatus(this.wire);
  final String wire;

  /// 已结案：客户端不再主动刷新它的进度。
  bool get isClosed => this != open && this != inProgress;

  static FeedbackStatus fromWire(Object? raw) => FeedbackStatus.values
      .firstWhere((FeedbackStatus s) => s.wire == raw, orElse: () => open);
}

/// 列表 / 批量进度用的摘要。
class FeedbackSummary {
  const FeedbackSummary({
    required this.id,
    required this.category,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.devReplyAt,
    this.userReplyAt,
    this.hasAccount = false,
    this.attachmentCount = 0,
    this.awaitingDev = false,
    this.flags = const <String>[],
  });

  factory FeedbackSummary.fromJson(FeedbackJson j) => FeedbackSummary(
    id: j['id'] as String,
    category: FeedbackCategory.fromWire(j['category']),
    title: _str(j['title']),
    status: FeedbackStatus.fromWire(j['status']),
    createdAt: _int(j['createdAt']),
    updatedAt: _int(j['updatedAt']),
    devReplyAt: _intOrNull(j['devReplyAt']),
    userReplyAt: _intOrNull(j['userReplyAt']),
    hasAccount: j['hasAccount'] == true,
    attachmentCount: j['attachments'] is num ? _int(j['attachments']) : 0,
    awaitingDev: j['awaitingDev'] == true,
    flags: List<String>.unmodifiable(
      ((j['flags'] as List<Object?>?) ?? const <Object?>[]).whereType<String>(),
    ),
  );

  final String id;
  final FeedbackCategory category;
  final String title;
  final FeedbackStatus status;
  final int createdAt;
  final int updatedAt;

  /// 开发者最近一次回复 / 改状态（反馈人侧「有新进展」）。
  final int? devReplyAt;
  final int? userReplyAt;

  // 以下只有开发者列表给。
  final bool hasAccount;
  final int attachmentCount;

  /// 反馈人在开发者上次处理后又说话了。
  final bool awaitingDev;

  /// 服务端打的风险标记（只有开发者接口给）：`injection` 疑似提示注入、`hidden_chars`
  /// 含已剥除的隐藏字符、`links` 链接较多、`duplicate:<id>` 与另一条内容相同。
  final List<String> flags;
}

/// 风险标记的种类（[FeedbackSummary.flags] 的解析结果）。
sealed class FeedbackFlag {
  const FeedbackFlag();

  /// 不认识的标记返回 null（旧客户端遇到新服务端时忽略即可）。
  static FeedbackFlag? parse(String raw) {
    if (raw.startsWith('duplicate:')) {
      return FeedbackDuplicateFlag(raw.substring(10));
    }
    return switch (raw) {
      'injection' => const FeedbackInjectionFlag(),
      'hidden_chars' => const FeedbackHiddenCharsFlag(),
      'links' => const FeedbackLinksFlag(),
      _ => null,
    };
  }
}

class FeedbackInjectionFlag extends FeedbackFlag {
  const FeedbackInjectionFlag();
}

class FeedbackHiddenCharsFlag extends FeedbackFlag {
  const FeedbackHiddenCharsFlag();
}

class FeedbackLinksFlag extends FeedbackFlag {
  const FeedbackLinksFlag();
}

class FeedbackDuplicateFlag extends FeedbackFlag {
  const FeedbackDuplicateFlag(this.ofId);

  /// 先到的那条反馈 id。
  final String ofId;
}

class FeedbackAttachmentInfo {
  const FeedbackAttachmentInfo({
    required this.slot,
    required this.kind,
    required this.bytes,
    required this.type,
  });

  factory FeedbackAttachmentInfo.fromJson(FeedbackJson j) =>
      FeedbackAttachmentInfo(
        slot: _str(j['slot']),
        kind: _str(j['kind']),
        bytes: j['bytes'] is num ? _int(j['bytes']) : 0,
        type: _str(j['type']),
      );

  /// `log` | `s0`..`s2`。
  final String slot;

  /// `log` | `screenshot`。
  final String kind;
  final int bytes;
  final String type;

  bool get isLog => kind == 'log';
}

class FeedbackMessage {
  const FeedbackMessage({
    required this.id,
    required this.fromDeveloper,
    required this.body,
    required this.createdAt,
    this.status,
    this.nickname,
  });

  factory FeedbackMessage.fromJson(FeedbackJson j) => FeedbackMessage(
    id: _int(j['id']),
    fromDeveloper: j['author'] == 'dev',
    body: _str(j['body']),
    createdAt: _int(j['createdAt']),
    status: j['status'] == null ? null : FeedbackStatus.fromWire(j['status']),
    nickname: j['nickname'] as String?,
  );

  final int id;
  final bool fromDeveloper;
  final String body;
  final int createdAt;

  /// 这条记录把状态改成了什么（纯回复为 null）。
  final FeedbackStatus? status;

  /// 开发者昵称（反馈人自己的消息为 null）。
  final String? nickname;
}

class FeedbackReporter {
  const FeedbackReporter({
    required this.id,
    required this.nickname,
    required this.discriminator,
  });

  factory FeedbackReporter.fromJson(FeedbackJson j) => FeedbackReporter(
    id: j['id'] as String,
    nickname: _str(j['nickname']),
    discriminator: _int(j['discriminator']),
  );

  final String id;
  final String nickname;
  final int discriminator;

  String get handle => '$nickname#${discriminator.toString().padLeft(4, '0')}';
}

/// 详情。反馈人视角没有 [contact] / [meta] / [reporter]。
class FeedbackDetail {
  const FeedbackDetail({
    required this.summary,
    required this.body,
    required this.attachments,
    required this.messages,
    this.contact = '',
    this.meta = const <String, Object?>{},
    this.origin = const <String, Object?>{},
    this.reporter,
  });

  factory FeedbackDetail.fromJson(FeedbackJson j) => FeedbackDetail(
    summary: FeedbackSummary.fromJson(j),
    body: _str(j['body']),
    attachments: _list(j['attachments'], FeedbackAttachmentInfo.fromJson),
    messages: _list(j['messages'], FeedbackMessage.fromJson),
    contact: _str(j['contact']),
    meta: j['meta'] is Map
        ? Map<String, Object?>.unmodifiable(_map(j['meta']))
        : const <String, Object?>{},
    origin: j['origin'] is Map
        ? Map<String, Object?>.unmodifiable(_map(j['origin']))
        : const <String, Object?>{},
    reporter: j['reporter'] == null
        ? null
        : FeedbackReporter.fromJson(_map(j['reporter'])),
  );

  final FeedbackSummary summary;
  final String body;
  final List<FeedbackAttachmentInfo> attachments;
  final List<FeedbackMessage> messages;
  final String contact;

  /// 客户端自报的设备 / 版本信息（可伪造）。
  final Map<String, Object?> meta;

  /// 服务端自己记录的来源（国家 / ASN / User-Agent / 是否签名），开发者接口才给。
  final Map<String, Object?> origin;
  final FeedbackReporter? reporter;

  String get id => summary.id;
  FeedbackStatus get status => summary.status;
}

/// 提交成功的回执：[ticket] 只在这一次返回，必须存下来才能再看进度。
class FeedbackReceipt {
  const FeedbackReceipt({
    required this.id,
    required this.ticket,
    required this.createdAt,
  });

  factory FeedbackReceipt.fromJson(FeedbackJson j) => FeedbackReceipt(
    id: j['id'] as String,
    ticket: j['ticket'] as String,
    createdAt: _int(j['createdAt']),
  );

  final String id;
  final String ticket;
  final int createdAt;
}

class FeedbackInboxPage {
  const FeedbackInboxPage({required this.items, this.next});

  factory FeedbackInboxPage.fromJson(FeedbackJson j) => FeedbackInboxPage(
    items: _list(j['items'], FeedbackSummary.fromJson),
    next: j['next'] as String?,
  );

  final List<FeedbackSummary> items;
  final String? next;
}
