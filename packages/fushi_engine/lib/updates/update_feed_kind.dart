/// 统一更新提醒的域枚举与事件身份构造（v101）。
///
/// 这一层是纯的：不碰数据库、不碰 UI，只回答两个问题——「有哪些域」和「这条
/// 事件的身份怎么拼」。四个投递方各自 import 它，身份格式因此只有一份定义。
library;

/// 更新提醒的域。值域**独立于**其它媒体枚举（`MediaKind` 等）：这里分的是
/// 「提醒的来源」而不是「媒体种类」——扩展更新和 app 更新根本不是媒体，硬塞
/// 进 `MediaKind` 只会让那个枚举多两个没人用的成员。跨域换算不存在，也不需要。
enum UpdateFeedKind {
  /// 订阅的番剧下载到新集。
  videoEpisode('videoEpisode'),

  /// 在线漫画（Mihon / Aidoku 源）出新章。
  mangaChapter('mangaChapter'),

  /// 已装漫画扩展有新版本。
  mangaExtension('mangaExtension'),

  /// Fushi 自身有新发布版本。
  appRelease('appRelease'),

  /// 已装视频（Aniyomi）扩展有新版本。与 [mangaExtension] 分开成域：两个生态的
  /// 扩展页、开关与「要不要提醒」各自独立，混成一个域就没法只关其中一边。
  ///
  /// **追加在末尾**：`updateNotificationId` 的分组 id 用 `index` 占高位，插在
  /// 中间会让既有域的分组通知 id 跨版本漂移，撤不掉上个进程发的那条。
  animeExtension('animeExtension');

  const UpdateFeedKind(this.dbValue);

  /// 落 `update_feed_entries.kind` 的字面量。与枚举名同形，但**显式写死**：
  /// 枚举名是可重构的代码符号，列值是已落地的数据，两者不该被同一次改名连坐。
  final String dbValue;

  /// 每个域一个「要不要提醒」的开关，落 `preferences`。
  String get enabledPrefKey => switch (this) {
    UpdateFeedKind.videoEpisode => 'updates_notify_video_episode',
    UpdateFeedKind.mangaChapter => 'updates_notify_manga_chapter',
    UpdateFeedKind.mangaExtension => 'updates_notify_manga_extension',
    UpdateFeedKind.animeExtension => 'updates_notify_anime_extension',
    UpdateFeedKind.appRelease => 'updates_notify_app_release',
  };

  /// 未登记的 [dbValue] 返回 null（旧版本写下的、本版本已删的域，读回来不该崩）。
  static UpdateFeedKind? fromDbValue(String value) {
    for (final UpdateFeedKind kind in UpdateFeedKind.values) {
      if (kind.dbValue == value) return kind;
    }
    return null;
  }
}

/// 系统通知总开关（关掉后仍照常投递、照常出红点，只是不弹系统通知）。
const String kUpdateSystemNotificationsPref = 'updates_system_notifications';

/// 已读条目的保留时长：超过这么久的**已读**条目会被清掉（未读的永不清，见
/// `pruneSeenUpdateFeedEntries`）。
const Duration kUpdateFeedSeenRetention = Duration(days: 30);

/// 事件主键 = `'<kind>|<targetKey>'`。
String updateFeedEntryId(UpdateFeedKind kind, String targetKey) =>
    '${kind.dbValue}|$targetKey';

/// 番剧新集的域内身份。集号带进身份是刻意的：下一集是**另一条**事件，不该
/// 复用上一集的已读状态。
String videoEpisodeTargetKey({
  required int collectionId,
  required String episodeKey,
}) => '$collectionId|$episodeKey';

/// 漫画新章的域内身份。
///
/// `bookKey` 是 `epub_books` 主键（在线漫画那支是 `<runtime>-<sha256 前 32>`，
/// 由源身份摘要而来，不随标题改名变化）；`chapterKey` 是**源内**章节身份
/// （Mihon = `chapter.url`，Aidoku = `chapter['key']`），与
/// `manga_chapter_states.chapterKey` 同一族——源刷新后章节顺序和索引都会变，
/// key 不变，所以这里同样刻意不用 index。
String mangaChapterTargetKey({
  required String bookKey,
  required String chapterKey,
}) => '$bookKey|$chapterKey';

/// 扩展新版的域内身份（漫画与视频扩展两个域共用）。带 versionCode：同一扩展的
/// 下一个版本是另一条事件。
String mangaExtensionTargetKey({
  required String packageName,
  required int versionCode,
}) => '$packageName|$versionCode';

/// 后台自动更新扩展的结果（[ExtensionAutoUpdateOutcome]）在更新中心的身份：
/// 在「有新版」那条身份后缀结果名。与「有新版」**不是同一条**事件——那条可能
/// 早就投递过（自动更新关着时、或上次被推迟），插入是幂等的，复用同一身份结果就
/// 永远落不进去。
String extensionAutoUpdateTargetKey({
  required String packageName,
  required int versionCode,
  required ExtensionAutoUpdateOutcome outcome,
}) =>
    '${mangaExtensionTargetKey(packageName: packageName, versionCode: versionCode)}'
    '|${outcome.name}';

/// 后台自动更新一个扩展的结局。
enum ExtensionAutoUpdateOutcome {
  /// 已装上新版。
  installed,

  /// 没装上，需要用户回扩展页手动处理（签名变了、下载失败……原因进 detailJson）。
  failed,
}

/// app 新版的域内身份 = 版本串本身。
String appReleaseTargetKey(String version) => version;
