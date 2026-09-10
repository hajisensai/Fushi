/// 统一更新提醒的服务层：**唯一**的投递入口与消费入口（v101）。
///
/// 四个域（番剧新集 / 漫画新章 / 漫画扩展新版 / app 新版）只调 [publishBatch]，
/// 剩下的事——开关过滤、幂等、系统通知合并、已读——全在这里，各域不再各写一遍。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, UpdateFeedEntriesCompanion, UpdateFeedEntryRow;

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_notifier.dart';

/// 一条待投递的更新事件。域侧只需填这些，身份拼接与落库由服务负责。
class UpdateFeedDraft {
  const UpdateFeedDraft({
    required this.kind,
    required this.targetKey,
    required this.title,
    this.subtitle,
    this.detailJson,
  });

  final UpdateFeedKind kind;
  final String targetKey;
  final String title;
  final String? subtitle;
  final String? detailJson;

  String get entryId => updateFeedEntryId(kind, targetKey);
}

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
class UpdateFeedService {
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

  /// 域 → 系统通知 id。同一个域重复发通知会**替换**上一条而不是叠出一串，
  /// 所以「订阅的番更新了 5 部」始终只占通知栏一格。
  static const Map<UpdateFeedKind, int> _notificationIds =
      <UpdateFeedKind, int>{
    UpdateFeedKind.videoEpisode: 9101,
    UpdateFeedKind.mangaChapter: 9102,
    UpdateFeedKind.mangaExtension: 9103,
    UpdateFeedKind.appRelease: 9104,
  };

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

  /// 投递一批事件。**同一域**的一批合成**一条**汇总通知。
  ///
  /// 为什么必须是批量入口：一轮订阅检查落 12 集是常态，逐条发通知等于把通知栏
  /// 刷屏。做成 List 入参后「一条」只是「一批里有一条」的特例，不需要额外分支。
  ///
  /// 关掉的域在这里就被整批丢弃——不投递、不出红点、不通知。「投递了但不提醒」
  /// 会让更新页里堆满用户明确说过不关心的东西。
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
    final bool sent = await _sendNotification(kind, fresh);
    return UpdateFeedPublishResult(newEntries: fresh, notificationSent: sent);
  }

  /// 单条投递的糖（[publishBatch] 的一元特例）。
  Future<UpdateFeedPublishResult> publish(UpdateFeedDraft draft) =>
      publishBatch(draft.kind, <UpdateFeedDraft>[draft]);

  Future<bool> _sendNotification(
    UpdateFeedKind kind,
    List<UpdateFeedDraft> fresh,
  ) async {
    if (!systemNotificationsEnabled) return false;
    _notifierReady ??= await _notifier.ensureReady();
    if (_notifierReady != true) return false;
    final UpdateNotificationText text = _notificationText(kind, fresh);
    await _notifier.notify(
      UpdateNotification(
        id: _notificationIds[kind]!,
        title: text.title,
        body: text.body,
        payload: kind.dbValue,
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
    if (kind != null) {
      await _notifier.cancel(_notificationIds[kind]!);
    } else {
      for (final int id in _notificationIds.values) {
        await _notifier.cancel(id);
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

/// 通知的标题与正文。纯数据，便于单测直接断言文案组装规则。
class UpdateNotificationText {
  const UpdateNotificationText({required this.title, required this.body});

  final String title;
  final String body;
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
