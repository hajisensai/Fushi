/// 统一更新提醒的服务层：**唯一**的投递入口与消费入口（v101）。
///
/// 四个域（番剧新集 / 漫画新章 / 漫画扩展新版 / app 新版）只调 [publishBatch]，
/// 剩下的事——开关过滤、幂等、系统通知合并、已读——全在这里，各域不再各写一遍。
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, UpdateFeedEntriesCompanion, UpdateFeedEntryRow;

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi_engine/updates/update_feed_port.dart';
// 纯数据与端口住在引擎（依赖方向 app → 引擎，见 update_feed_port.dart）；
// 这里 re-export 让既有调用点照旧只 import 本文件。
export 'package:fushi_engine/updates/update_feed_port.dart'
    show UpdateFeedDraft, UpdateFeedPublisher;
import 'package:fushi/src/updates/update_notifier.dart';


/// 一次投递的结果。域侧一般不用看，[newEntries] 供调用方写日志或做后续动作。
class UpdateFeedPublishResult {
  const UpdateFeedPublishResult({
    required this.newEntries,
    required this.notificationSent,
  });

  /// 本轮**第一次**出现的事件（已经投递过的不在内）。
  final List<UpdateFeedDraft> newEntries;

  /// 是否真的发出了系统通知（开关关、权限被拒、无新事件时为 false）。
  final bool notificationSent;

  bool get hasNew => newEntries.isNotEmpty;
}

/// 更新提醒服务。
///
/// 生命周期：随 `AppModel` 一份，进程内单例。它**不自己起定时器**——什么时候去
/// 检查是各域自己的事（番剧走既有订阅检查节奏、漫画走库更新调度、app 走启动检查），
/// 这里只负责「发现了之后怎么办」。把调度也塞进来会让这一层同时owning四种完全
/// 不同的节奏，而那四种节奏本来就该由最懂它的域来定。
/// 投递实现：端口定义在引擎侧（[UpdateFeedPublisher]），依赖方向 app → 引擎。
/// 显式 implements 是有意的——不写的话，端口签名将来改了这里不会被编译器拦住。
class UpdateFeedService implements UpdateFeedPublisher {
  UpdateFeedService({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    UpdateNotifier notifier = const NoopUpdateNotifier(),
    DateTime Function() now = DateTime.now,
    UpdateNotificationText Function(UpdateFeedKind, List<UpdateFeedDraft>)?
        notificationText,
  })  : _db = database,
        _prefs = prefs,
        _notifier = notifier,
        _now = now,
        _notificationText = notificationText ?? updateNotificationText;

  final FushiDatabase _db;
  final PreferencesRepository _prefs;
  final UpdateNotifier _notifier;
  final DateTime Function() _now;

  /// 通知文案组装。默认是 [updateNotificationText]（纯结构、无 i18n）；装配处
  /// （`AppModel`）注入带 slang `t` 的实现，把「3 部作品更新」这类句子本地化。
  /// 走注入而不是在这里 import `t`：这一层要能在纯 Dart 单测里跑，slang 的 `t`
  /// 需要 Flutter binding。
  final UpdateNotificationText Function(UpdateFeedKind, List<UpdateFeedDraft>)
      _notificationText;

  /// 通知权限只申请一次；null = 还没问过。
  bool? _notifierReady;

  /// 本进程内发过的通知 id，按域——[markAllSeen] 撤通知时要知道该域挂着哪些
  /// （分组通知的 id 由组名派生，事先不可枚举）。
  final Map<UpdateFeedKind, Set<int>> _shownIds = <UpdateFeedKind, Set<int>>{};

  /// 这个域要不要提醒。默认全开——用户装了订阅功能就是想被告知，默认关等于功能
  /// 不存在。
  bool isKindEnabled(UpdateFeedKind kind) =>
      _prefs.getPref(kind.enabledPrefKey, defaultValue: true) as bool;

  Future<void> setKindEnabled(UpdateFeedKind kind, bool enabled) =>
      _prefs.setPref(kind.enabledPrefKey, enabled);

  /// 系统通知总开关。默认开；关掉后仍照常投递、照常出红点。
  bool get systemNotificationsEnabled =>
      _prefs.getPref(kUpdateSystemNotificationsPref, defaultValue: true) as bool;

  Future<void> setSystemNotificationsEnabled(bool enabled) async {
    await _prefs.setPref(kUpdateSystemNotificationsPref, enabled);
  }

  /// 启动期把通知后端初始化好：注册点击回调、回放「被通知冷启动」的那次点击、
  /// 让上个进程留下的通知能被撤销。没有这一步，回调只在本进程**第一次发通知**
  /// 时才挂上——重启后点昨晚那条「播放」什么都不发生。总开关关着就不初始化
  /// （Android 13+ 初始化会弹权限）。
  Future<void> warmUpNotifier() async {
    if (!systemNotificationsEnabled) return;
    _notifierReady ??= await _notifier.ensureReady();
  }

  /// 投递一批事件。**同一域**的一批合成**一条**汇总通知。
  ///
  /// 为什么必须是批量入口：一轮订阅检查落 12 集是常态，逐条发通知等于把通知栏
  /// 刷屏。做成 List 入参后「一条」只是「一批里有一条」的特例，不需要额外分支。
  ///
  /// 关掉的域在这里就被整批丢弃——不投递、不出红点、不通知。「投递了但不提醒」
  /// 会让更新页里堆满用户明确说过不关心的东西。
  @override
  Future<UpdateFeedPublishResult> publishBatch(
    UpdateFeedKind kind,
    List<UpdateFeedDraft> drafts,
  ) async {
    if (drafts.isEmpty || !isKindEnabled(kind)) {
      return const UpdateFeedPublishResult(
        newEntries: <UpdateFeedDraft>[],
        notificationSent: false,
      );
    }
    final int discoveredAt = _now().millisecondsSinceEpoch;
    final List<UpdateFeedDraft> fresh = <UpdateFeedDraft>[];
    for (final UpdateFeedDraft draft in drafts) {
      if (draft.kind != kind) {
        throw ArgumentError.value(
          draft.kind,
          'drafts',
          'publishBatch 的 drafts 必须与 kind 同域（通知按域合并，混域会把两个域的'
              '更新算进同一条通知）',
        );
      }
      final bool inserted = await _db.insertUpdateFeedEntry(
        UpdateFeedEntriesCompanion.insert(
          entryId: draft.entryId,
          kind: kind.dbValue,
          targetKey: draft.targetKey,
          title: draft.title,
          subtitle: Value<String?>(draft.subtitle),
          detailJson: Value<String?>(draft.detailJson),
          discoveredAt: discoveredAt,
        ),
      );
      if (inserted) fresh.add(draft);
    }
    if (fresh.isEmpty) {
      return const UpdateFeedPublishResult(
        newEntries: <UpdateFeedDraft>[],
        notificationSent: false,
      );
    }
    // 按通知组拆：同组一条汇总（番剧域 = 一部作品一条），无组的整域一条。
    // 组在 [drafts] 里首次出现的顺序即通知顺序，稳定可断言。
    final Map<String?, List<UpdateFeedDraft>> byGroup =
        <String?, List<UpdateFeedDraft>>{};
    for (final UpdateFeedDraft draft in fresh) {
      byGroup
          .putIfAbsent(draft.notificationGroup, () => <UpdateFeedDraft>[])
          .add(draft);
    }
    bool sent = false;
    for (final MapEntry<String?, List<UpdateFeedDraft>> group
        in byGroup.entries) {
      sent = await _sendNotification(kind, group.key, group.value) || sent;
    }
    return UpdateFeedPublishResult(newEntries: fresh, notificationSent: sent);
  }

  /// 单条投递的糖（[publishBatch] 的一元特例）。
  Future<UpdateFeedPublishResult> publish(UpdateFeedDraft draft) =>
      publishBatch(draft.kind, <UpdateFeedDraft>[draft]);

  Future<bool> _sendNotification(
    UpdateFeedKind kind,
    String? group,
    List<UpdateFeedDraft> fresh,
  ) async {
    if (!systemNotificationsEnabled) return false;
    _notifierReady ??= await _notifier.ensureReady();
    if (_notifierReady != true) return false;
    final UpdateNotificationText text = _notificationText(kind, fresh);
    final UpdateFeedDraft first = fresh.first;
    final int id = updateNotificationId(kind, group);
    _shownIds.putIfAbsent(kind, () => <int>{}).add(id);
    final int? publishedAt = first.publishedAt;
    await _notifier.notify(
      UpdateNotification(
        id: id,
        title: text.title,
        body: text.body,
        // 载荷指向组内第一条：点通知就落到它（番剧 = 播这一集）。
        payload: UpdateNotificationPayload(
          kind: kind,
          entryId: first.entryId,
        ).encode(),
        imagePath: first.imagePath,
        timestamp: publishedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(publishedAt),
        actions: <UpdateNotificationAction>[
          if (text.openLabel case final String label)
            UpdateNotificationAction(
              id: kUpdateNotificationActionOpen,
              label: label,
            ),
          if (text.viewAllLabel case final String label)
            UpdateNotificationAction(
              id: kUpdateNotificationActionViewAll,
              label: label,
            ),
        ],
      ),
    );
    return true;
  }

  /// 未读计数，按域。域无未读时**键不出现**。
  Future<Map<UpdateFeedKind, int>> unseenCounts() async {
    final Map<String, int> raw = await _db.unseenUpdateFeedCountsByKind();
    return <UpdateFeedKind, int>{
      for (final MapEntry<String, int> e in raw.entries)
        if (UpdateFeedKind.fromDbValue(e.key) case final UpdateFeedKind kind)
          kind: e.value,
    };
  }

  /// 未读总数（侧栏红点）。
  Future<int> unseenTotal() async {
    final Map<UpdateFeedKind, int> counts = await unseenCounts();
    return counts.values.fold<int>(0, (int a, int b) => a + b);
  }

  Future<List<UpdateFeedEntryRow>> entries({
    Set<UpdateFeedKind> kinds = const <UpdateFeedKind>{},
    bool unseenOnly = false,
    int limit = 200,
  }) =>
      _db.updateFeedEntriesPage(
        kinds: <String>{for (final UpdateFeedKind k in kinds) k.dbValue},
        unseenOnly: unseenOnly,
        limit: limit,
      );

  Future<void> markSeen(Iterable<String> entryIds) => _db
      .markUpdateFeedEntriesSeen(entryIds, seenAt: _now().millisecondsSinceEpoch);

  /// 全部标已读；[kind] 非空时只标该域，并撤掉该域挂着的系统通知（用户已经在
  /// 应用内看过了，通知栏还挂着就是重复打扰）。
  Future<void> markAllSeen({UpdateFeedKind? kind}) async {
    await _db.markAllUpdateFeedSeen(
      kind: kind?.dbValue,
      seenAt: _now().millisecondsSinceEpoch,
    );
    final List<UpdateFeedKind> kinds =
        kind == null ? UpdateFeedKind.values : <UpdateFeedKind>[kind];
    for (final UpdateFeedKind k in kinds) {
      // 域级固定 id 总撤（上个进程留下的那条不在 [_shownIds] 里）；分组 id 撤本
      // 进程发过的。
      final int baseId = updateNotificationId(k, null);
      await _notifier.cancel(baseId);
      for (final int id in _shownIds.remove(k) ?? const <int>{}) {
        if (id != baseId) await _notifier.cancel(id);
      }
    }
  }

  /// 清掉过老的**已读**条目（未读的一条不动，见 DAO 注释）。启动时跑一次即可。
  Future<int> pruneSeen({Duration retention = kUpdateFeedSeenRetention}) =>
      _db.pruneSeenUpdateFeedEntries(
        seenBefore: _now().subtract(retention).millisecondsSinceEpoch,
      );

  Stream<void> watchChanged() => _db.watchUpdateFeedChanged();
}

/// 域 → 系统通知的固定 id（v101 起就是这四个值，跨版本稳定：撤销要按同一个
/// id 找到上个进程发出的那条）。
const Map<UpdateFeedKind, int> kUpdateNotificationBaseIds =
    <UpdateFeedKind, int>{
  UpdateFeedKind.videoEpisode: 9101,
  UpdateFeedKind.mangaChapter: 9102,
  UpdateFeedKind.mangaExtension: 9103,
  UpdateFeedKind.appRelease: 9104,
};

/// 通知 id：无组 = 域固定 id；有组 = 域序号占高 4 位 + 组名 FNV-1a 哈希占低
/// 28 位（Android 通知 id 是 32 位有符号 int，取正数范围）。同域同组恒同 id，
/// 所以「A 又更新了」替换而不是叠加；不用 `String.hashCode`——它不保证跨进程
/// 稳定，撤不到上个进程发的那条。
int updateNotificationId(UpdateFeedKind kind, String? group) {
  if (group == null) return kUpdateNotificationBaseIds[kind]!;
  int hash = 0x811C9DC5;
  for (final int unit in group.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return ((kind.index + 1) << 28) | (hash & 0x0FFFFFFF);
}

/// 通知按钮 id：打开那条更新的落点（视频 = 播放该集，漫画 = 作品页，扩展 =
/// 扩展页，app = 发布页）。点通知本体与它同义。
const String kUpdateNotificationActionOpen = 'open';

/// 通知按钮 id：进更新中心。
const String kUpdateNotificationActionViewAll = 'view_all';

/// 通知点击载荷：只带身份，落点从数据库还原（`getUpdateFeedEntry`），通知里不
/// 复制一份 detailJson——那份可能在发出后被域侧更新。
class UpdateNotificationPayload {
  const UpdateNotificationPayload({required this.kind, required this.entryId});

  final UpdateFeedKind kind;
  final String entryId;

  String encode() => jsonEncode(<String, String>{
        'kind': kind.dbValue,
        'entryId': entryId,
      });

  /// 解不出（旧版本发的裸 `kind.dbValue`、损坏）返回 null，调用方退到更新中心。
  static UpdateNotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final UpdateFeedKind? kind =
          UpdateFeedKind.fromDbValue(decoded['kind'] as String? ?? '');
      final String? entryId = decoded['entryId'] as String?;
      if (kind == null || entryId == null) return null;
      return UpdateNotificationPayload(kind: kind, entryId: entryId);
    } on FormatException {
      return null;
    }
  }
}

/// 解一条更新的 `detailJson`（本机自己写的）。坏掉只可能是版本间格式漂移——
/// 那时「打不开 / 不显示」比崩掉好，返回空表。
Map<String, Object?> decodeUpdateFeedDetail(String? json) {
  if (json == null || json.isEmpty) return const <String, Object?>{};
  try {
    final Object? decoded = jsonDecode(json);
    return decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
  } on FormatException {
    return const <String, Object?>{};
  }
}

/// 通知的标题与正文。纯数据，便于单测直接断言文案组装规则。
class UpdateNotificationText {
  const UpdateNotificationText({
    required this.title,
    required this.body,
    this.openLabel,
    this.viewAllLabel,
  });

  final String title;
  final String body;

  /// 「打开落点」按钮文案；null = 不放按钮（默认纯结构实现没有 i18n，给 null）。
  final String? openLabel;

  /// 「查看更新」按钮文案；null 同上。
  final String? viewAllLabel;
}

/// 通知文案的组装规则（纯函数）。
///
/// 一条时给具体作品名 + 副标题；多条时给「第一部 等 N 项」——把每一项都拼进正文
/// 在 12 集的常态下会被系统截断成一堆省略号，还不如只说清「有几项、从哪开始」。
///
/// **刻意不在这里查 i18n**：这一层要能在纯 Dart 单测里跑，而 slang 的 `t` 需要
/// Flutter binding。调用方（`UpdateFeedService` 的使用者）负责本地化外壳，这里
/// 只组装结构——当前实现取 draft 自带的、已本地化好的 title/subtitle。
UpdateNotificationText updateNotificationText(
  UpdateFeedKind kind,
  List<UpdateFeedDraft> fresh,
) {
  final UpdateFeedDraft first = fresh.first;
  if (fresh.length == 1) {
    return UpdateNotificationText(
      title: first.title,
      body: first.subtitle ?? '',
    );
  }
  final String firstLine =
      first.subtitle == null ? first.title : '${first.title} · ${first.subtitle}';
  return UpdateNotificationText(
    title: first.title,
    body: '$firstLine +${fresh.length - 1}',
  );
}
