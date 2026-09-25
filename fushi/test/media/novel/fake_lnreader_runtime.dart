import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_runtime.dart';

/// 测试用的插件执行面：不起 WebView，按脚本返回结果并记录调用。
class FakeLnReaderRuntime implements LnReaderRuntime {
  FakeLnReaderRuntime({
    this.items = const <LnReaderNovelItem>[],
    this.novelResult,
    this.chapterHtml = const <String, String>{},
    this.failingChapters = const <String>{},
    this.filters = const <LnReaderFilter>[],
  });

  List<LnReaderNovelItem> items;
  LnReaderNovel? novelResult;
  Map<String, String> chapterHtml;
  Set<String> failingChapters;
  List<LnReaderFilter> filters;

  final List<String> loaded = <String>[];
  final List<String> forgotten = <String>[];
  final List<String> calls = <String>[];
  final List<Map<String, Object?>?> popularFilters = <Map<String, Object?>?>[];
  bool disposed = false;

  @override
  Future<LnReaderPluginInfo> ensureLoaded(
    String pluginId,
    Future<LnReaderPluginSource> Function() source,
  ) async {
    await source();
    loaded.add(pluginId);
    return LnReaderPluginInfo(
      id: pluginId,
      name: pluginId,
      site: 'https://example.com/',
      version: '1.0.0',
      filters: filters,
      imageHeaders: const <String, String>{},
      hasParsePage: false,
    );
  }

  @override
  Future<void> forget(String pluginId) async => forgotten.add(pluginId);

  @override
  Future<List<LnReaderNovelItem>> popular(
    String pluginId, {
    required int page,
    required bool latest,
    Map<String, Object?>? filters,
  }) async {
    calls.add('popular:$page:$latest');
    popularFilters.add(filters);
    return page == 1 ? items : const <LnReaderNovelItem>[];
  }

  @override
  Future<List<LnReaderNovelItem>> search(
    String pluginId, {
    required String query,
    required int page,
  }) async {
    calls.add('search:$query:$page');
    return page == 1 ? items : const <LnReaderNovelItem>[];
  }

  @override
  Future<LnReaderNovel> novel(String pluginId, String path) async {
    calls.add('novel:$path');
    return novelResult!;
  }

  @override
  Future<String> chapter(String pluginId, String path) async {
    calls.add('chapter:$path');
    if (failingChapters.contains(path)) throw StateError('boom $path');
    return chapterHtml[path] ?? '<p>$path</p>';
  }

  @override
  Future<String> resolveUrl(
    String pluginId,
    String path, {
    required bool isNovel,
  }) async => 'https://example.com$path';

  /// 不跑 DOMParser：原样当 XHTML 用，`<img src="x">` 按宿主约定改名。
  @override
  Future<LnReaderXhtml> toXhtml(
    String html, {
    required String baseUrl,
    required String imagePrefix,
  }) async {
    final List<({String url, String fileName})> images =
        <({String url, String fileName})>[];
    final String xhtml = html.replaceAllMapped(
      RegExp(r'<img src="([^"]+)"\s*/?>'),
      (Match match) {
        final String fileName = '$imagePrefix${images.length}.png';
        images.add((url: match.group(1)!, fileName: fileName));
        return '<img src="$fileName" alt=""/>';
      },
    );
    return LnReaderXhtml(xhtml: xhtml, images: images);
  }

  @override
  Future<void> dispose() async => disposed = true;
}
