import 'dart:io';

import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

/// 共享测试基类：[HibikiLibraryHostService] 有 26 个方法，绝大多数 live/server 测试
/// 只关心其中一小簇（词典 / 书籍 / 视频 / 有声书之一），其余方法此前在每个测试文件里
/// 逐字复制成同一套「空实现存根」。此基类把这套存根上移为唯一真相源：
///
/// - 每个测试文件的 fake 改为 `extends FakeLibraryHostServiceBase`，只 override 它真正
///   行使的方法、只声明它断言用到的字段（`deleted` / `imported` / `books` 等名字与断言
///   逐字保留）。
/// - 未被 override 的方法走本基类默认值：列表返回空、导出抛 [UnimplementedError]
///   （「不该被调用」的响亮守卫）、导入/删除 no-op、位置返回 (0,0)。
/// - 书籍阅读进度 round-trip（[bookProgress] + [getBookProgress] / [putBookProgress]）在
///   所有文件里字节一致，故直接落基类（子类断言 `lib.bookProgress[...]` 仍然可用）。
///
/// 每个具体方法本身可被子类完全 override，故不会破坏任何既有测试语义。
class FakeLibraryHostServiceBase implements HibikiLibraryHostService {
  // ── 词典 ─────────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('exportDictionary not stubbed for this test');

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  // ── 书籍 ─────────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('exportBook not stubbed for this test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  /// host 端每书阅读进度真相源；round-trip 语义在所有测试里一致，故落基类。
  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    final RemoteBookProgress current =
        bookProgress[bookKey] ?? RemoteBookProgress.empty;
    bookProgress[bookKey] =
        resolveBookProgressSync(local: current, remote: progress);
  }

  // ── 本地音频 ───────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('exportLocalAudio not stubbed for this test');

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  // ── 有声书包 ──────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError('exportAudiobook not stubbed for this test');

  @override
  Future<bool> audiobookExists(String bookKey) async => false;

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {}

  // ── 视频 ──────────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<bool> videoExists(String id) async => false;

  @override
  Future<void> importVideoSubtitle(File subtitleFile,
      {required String id, required String suffix}) async {}

  @override
  Future<void> importVideo(File videoFile,
      {required String id,
      required String title,
      String? originalFileName}) async {}

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      null;

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}

  // BUG-1004：host 端裁 mining 句子音频（多数测试不涉及，返 null 即可）。
  @override
  Future<File?> clipVideoAudio(String id,
          {required int startMs,
          required int endMs,
          int episodeIndex = 0,
          int? audioStreamIndex,
          int? audioStreamCount,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async =>
      null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
          {int limit = 100}) async =>
      const <RemoteActivityEvent>[];

  @override
  Future<String?> videoCoverPath(String id) async {
    for (final RemoteVideoInfo v in await listVideos()) {
      if (v.id == id) return v.coverPath;
    }
    return null;
  }

  @override
  Future<String?> bookCoverPath(String id) async {
    for (final RemoteBookInfo b in await listBooks()) {
      if (b.downloadId == id || b.title == id) return b.coverPath;
    }
    return null;
  }

  // ── 聚合 / 合集 ────────────────────────────────────────────────────────────
  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {}

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  Future<CollectionManifest> mergeCollectionManifest(
          CollectionManifest incoming) async =>
      incoming;
}
