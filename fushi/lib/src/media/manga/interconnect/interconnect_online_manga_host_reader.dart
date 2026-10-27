import 'dart:typed_data';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi_engine/sync/online_manga_host_reader.dart';

/// 互联 host 侧：用本机在线漫画运行时给对端现取**没下载的章**。
///
/// 对端（尤其 iPhone——按 App Store 合规本机没有在线源宿主）经互联读 host 书架上的
/// Mihon / 网页漫画条目，取页走的是 host 自己的运行时，与 host 本机在线直读同一对
/// `resolveChapterPages` / `fetchChapterPage`。
///
/// 只认领 host 本平台真有运行时的条目：iOS host、Aidoku 遗留条目、以及本身就是从
/// 别的 host 收来的互联条目（不做二跳转发）一律 [canServe] false，对端只看到已下载的章。
class InterconnectOnlineMangaHostReader implements OnlineMangaHostReader {
  InterconnectOnlineMangaHostReader(this._serviceFor);

  /// 按 runtime 取书架服务（生产 = `AppModel.onlineMangaLibraryService`）。
  final OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
  _serviceFor;

  /// 最近几章的页表：对端逐页取图，每页都重新解析整章页表会把源站打爆。失败的
  /// 解析不留（下次重试），容量够覆盖「当前章 + 预取下一章」再加几章余量。
  final Map<String, Future<List<OnlineMangaPageRef>>> _pageTables =
      <String, Future<List<OnlineMangaPageRef>>>{};
  static const int _pageTableCapacity = 8;

  @override
  bool canServe(String sourceMetadata) {
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      sourceMetadata,
    );
    if (entry == null) return false;
    return _runtimeAvailable(entry.runtime);
  }

  @override
  Future<int> chapterPageCount({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
  }) async => (await _pages(bookKey, sourceMetadata, chapter)).length;

  @override
  Future<Uint8List> chapterPage({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
    required int index,
  }) async {
    final List<OnlineMangaPageRef> pages = await _pages(
      bookKey,
      sourceMetadata,
      chapter,
    );
    RangeError.checkValidIndex(index, pages, 'index');
    final OnlineMangaLibraryEntry entry = _parse(sourceMetadata);
    return _serviceFor(entry.runtime).adapter.fetchChapterPage(pages[index]);
  }

  Future<List<OnlineMangaPageRef>> _pages(
    String bookKey,
    String sourceMetadata,
    Map<String, Object?> chapterJson,
  ) {
    final OnlineMangaLibraryEntry entry = _parse(sourceMetadata);
    if (!_runtimeAvailable(entry.runtime)) {
      throw StateError('online manga runtime unavailable: ${entry.runtime}');
    }
    final OnlineMangaChapter? chapter = OnlineMangaChapter.fromJson(
      chapterJson,
    );
    if (chapter == null) {
      throw StateError('malformed online manga chapter: $bookKey');
    }
    final String cacheKey = '$bookKey\u0000${chapter.key}';
    final Future<List<OnlineMangaPageRef>>? cached = _pageTables.remove(
      cacheKey,
    );
    if (cached != null) {
      // 重新插到末尾 = 最近使用。
      _pageTables[cacheKey] = cached;
      return cached;
    }
    final Future<List<OnlineMangaPageRef>> resolving = _serviceFor(
      entry.runtime,
    ).adapter.resolveChapterPages(entry: entry, chapter: chapter);
    _pageTables[cacheKey] = resolving;
    while (_pageTables.length > _pageTableCapacity) {
      _pageTables.remove(_pageTables.keys.first);
    }
    resolving.catchError((Object _) {
      if (identical(_pageTables[cacheKey], resolving)) {
        _pageTables.remove(cacheKey);
      }
      return const <OnlineMangaPageRef>[];
    });
    return resolving;
  }

  static OnlineMangaLibraryEntry _parse(String sourceMetadata) {
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      sourceMetadata,
    );
    if (entry == null) {
      throw StateError('not an online manga entry');
    }
    return entry;
  }

  /// 判据不碰 `AppModel.mihonManager`：它在没有 Mihon 宿主的平台上直接抛。
  static bool _runtimeAvailable(OnlineMangaRuntimeKind runtime) {
    if (!StoreRestrictedCapability.onlineMangaSource.isAvailable) return false;
    switch (runtime) {
      case OnlineMangaRuntimeKind.mihon:
        return MihonRuntimeFactory.isSupported;
      case OnlineMangaRuntimeKind.web:
        return true;
      case OnlineMangaRuntimeKind.aidoku:
      case OnlineMangaRuntimeKind.interconnect:
      // Kavita 条目在本机直连用户自己的服务器读，互联 host 不代读。
      case OnlineMangaRuntimeKind.kavita:
        return false;
    }
  }
}
