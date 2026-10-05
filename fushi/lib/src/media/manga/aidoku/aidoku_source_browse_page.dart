import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_cover_image.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/online/online_source_browse_page.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// Catalog browser for one installed Aidoku source.
///
/// 页面本体是三域共用的 [OnlineSourceBrowsePage]（2026-09-27「浏览」阶段 2）；
/// 这里只剩 Aidoku 的差异（[_AidokuCatalog]）：浏览列表是包自己声明的 listing，
/// 没有筛选，封面带源站 Referer。
class AidokuSourceBrowsePage extends StatefulWidget {
  const AidokuSourceBrowsePage({
    required this.package,
    super.key,
    this.runtime,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime? runtime;

  @override
  State<AidokuSourceBrowsePage> createState() => _AidokuSourceBrowsePageState();
}

class _AidokuSourceBrowsePageState extends State<AidokuSourceBrowsePage> {
  late final _AidokuCatalog _catalog = _AidokuCatalog(
    package: widget.package,
    runtime: widget.runtime ?? AidokuRuntimeFactory.create(),
  );

  @override
  Widget build(BuildContext context) =>
      OnlineSourceBrowsePage<Map<String, Object?>>(catalog: _catalog);
}

class _AidokuCatalog extends OnlineSourceCatalog<Map<String, Object?>> {
  _AidokuCatalog({required this.package, required this.runtime});

  final AidokuInstalledPackage package;
  final AidokuRuntime runtime;
  List<AidokuListing> _listings = const <AidokuListing>[];
  String? _sourceBaseUrl;

  @override
  String get title => package.name;

  @override
  String get searchHint => t.mihon_source_search;

  @override
  String get keyPrefix => 'aidoku_source';

  @override
  Future<void> prepare() async {
    final AidokuPackageInspection inspection = await runtime.inspect(
      package.packagePath,
    );
    _listings = inspection.listings;
    _sourceBaseUrl = (inspection.sourceInfo['urls'] as List<Object?>?)
        ?.map((Object? value) => value.toString())
        .where((String value) => Uri.tryParse(value)?.isScheme('https') == true)
        .firstOrNull;
  }

  /// listing 没有稳定 id，用声明序做身份（同一个包的 listing 顺序固定）。
  @override
  List<OnlineBrowseListing> get listings => <OnlineBrowseListing>[
    for (int index = 0; index < _listings.length; index++)
      OnlineBrowseListing(id: '$index', label: _listings[index].name),
  ];

  @override
  bool get hasFilters => false;

  @override
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context) async =>
      null;

  @override
  Future<OnlineBrowsePageResult<Map<String, Object?>>> fetch(
    OnlineBrowseQuery query,
    int page,
  ) async {
    final int? listingIndex = int.tryParse(query.listingId ?? '');
    final Map<String, Object?> result =
        listingIndex == null ||
            listingIndex < 0 ||
            listingIndex >= _listings.length
        ? await runtime.search(
            package.packagePath,
            query: query.text,
            page: page,
          )
        : await runtime.browse(
            package.packagePath,
            _listings[listingIndex],
            page: page,
          );
    final List<Map<String, Object?>> entries =
        (result['entries'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> value) => value.cast<String, Object?>())
            .where(
              (Map<String, Object?> value) =>
                  (value['key']?.toString().isNotEmpty ?? false),
            )
            .toList(growable: false);
    return (items: entries, hasNextPage: result['has_next_page'] == true);
  }

  @override
  String keyOf(Map<String, Object?> item) => item['key'].toString();

  @override
  String titleOf(Map<String, Object?> item) =>
      item['title']?.toString() ?? item['key'].toString();

  @override
  Widget buildCover(BuildContext context, Map<String, Object?> item) =>
      AidokuCoverImage(url: item['cover']?.toString(), referer: _sourceBaseUrl);

  @override
  void Function(BuildContext, Map<String, Object?>)? get openDetail =>
      _openDetails;

  void _openDetails(BuildContext context, Map<String, Object?> manga) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => AidokuMangaDetailPage(
          package: package,
          runtime: runtime,
          manga: manga,
          sourceBaseUrl: _sourceBaseUrl,
        ),
      ),
    );
  }

  /// Cloudflare 拦截给专门文案（见 [aidokuErrorMessage]）。
  @override
  String describeError(Object error) => aidokuErrorMessage(error);

  /// Aidoku 的无头运行时解不了 Cloudflare 挑战，没有可点的验证入口。
  ///
  /// 2026-10 体验优化：这里原先把错误文字再画一遍，与页面行内错误重复显示
  /// 两次；文案改由 [describeError] 单出口。
  @override
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  }) => const SizedBox.shrink();
}

/// 源浏览里的作品页入口。
///
/// v88 前这里是个**瞬时**详情页：章节列表只活在 widget state 里，页面 pop 即丢；
/// `aidoku/` 全目录一处 `insertEpubBook` 都没有，所以 Aidoku 的作品根本进不了
/// 书架，读进度也无处可落。
///
/// 现在它只把 Aidoku 的包/作品翻译成运行时无关的 seed，页面本体交给
/// [MangaSeriesPage] —— 加入书架、每章已读、断点续读从此与 Mihon 同一套。
class AidokuMangaDetailPage extends ConsumerWidget {
  const AidokuMangaDetailPage({
    required this.package,
    required this.runtime,
    required this.manga,
    required this.sourceBaseUrl,
    super.key,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime runtime;
  final Map<String, Object?> manga;
  final String? sourceBaseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 拿不到 AppModel 是**正常状态**，不是错误：这一页展示所需的一切都在
    // adapter 里，AppModel 只决定「能不能加入书架」。硬读会让这一页在没有
    // ProviderScope 的树里直接崩（widget 测试正是这么立起来的）。
    AppModel? appModel;
    try {
      appModel = ref.read(appProvider);
    } on Object {
      appModel = null;
    }
    return MangaSeriesPage(
      target: SourceMangaSeriesTarget(
        // 包与 runtime 都已在手：预置进去，别让作品页再去扫一遍已安装包列表。
        adapter: AidokuLibraryAdapter(
          runtime: runtime,
          presetPackage: package,
        ),
        // 刻意不走 AppModel.onlineMangaLibraryService：那条分派恒用
        // AidokuRuntimeFactory.create()，会把这里注入的 runtime（测试替身、
        // 或浏览页已经建好的那一份）丢掉。拿不到 AppModel 时留空——展示照旧，
        // 只是不能入库。
        service: appModel == null
            ? null
            : OnlineMangaLibraryService(
                database: appModel.database,
                rootDirectory: appModel.aidokuLibraryRoot,
                adapter: AidokuLibraryAdapter(
                  runtime: runtime,
                  presetPackage: package,
                ),
              ),
        seed: OnlineMangaLibraryEntry(
          runtime: OnlineMangaRuntimeKind.aidoku,
          // Aidoku 是单源包：包 id 同时充当扩展身份和源身份。
          extensionPackage: package.id,
          sourceId: package.id,
          series: AidokuLibraryAdapter.seriesOf(
            manga,
            fallbackKey: manga['key']?.toString() ?? '',
          ),
          // 网格上只有标题和封面；章节由作品页进页后自己拉。
          chapters: const <OnlineMangaChapter>[],
        ),
        sourceLabel: package.name,
        remoteCoverBuilder: (BuildContext context) => AidokuCoverImage(
          url: manga['cover']?.toString(),
          referer: _aidokuHttpsUrl(manga['url']) ?? sourceBaseUrl,
        ),
      ),
    );
  }
}

/// User-facing text for an Aidoku failure.
///
/// Cloudflare-protected sources (MangaFire, Comix, …) can't be reached by the
/// headless WebAssembly runtime — it has no browser to solve the JavaScript
/// challenge — so the runtime surfaces a dedicated `CLOUDFLARE_CHALLENGE` code
/// instead of an opaque `JsonParseError`. Turn that into an actionable line
/// rather than dumping the exception's `toString()`.
String aidokuErrorMessage(Object? error) {
  if (error is AidokuRuntimeException &&
      error.code == kAidokuCloudflareChallengeCode) {
    return t.manga_source_cloudflare_blocked;
  }
  if (error == null) return t.online_source_error_generic;
  return describeOnlineSourceError(error);
}

/// Aidoku 章节的展示标题：标题为空时回退到卷/话号。
///
/// 公开是因为 `AidokuLibraryAdapter.chaptersOf` 归一化章节时要用同一份
/// 回退逻辑——复制一份必然和这里漂移。
String aidokuChapterDisplayTitle(Map<String, Object?> chapter) {
  final String title = chapter['title']?.toString().trim() ?? '';
  if (title.isNotEmpty) return title;
  final String volume = _aidokuNumber(chapter['volume_number']);
  final String number = _aidokuNumber(chapter['chapter_number']);
  if (volume.isNotEmpty && number.isNotEmpty) {
    return 'Vol. $volume · Ch. $number';
  }
  if (number.isNotEmpty) return 'Ch. $number';
  if (volume.isNotEmpty) return 'Vol. $volume';
  return chapter['key']?.toString() ?? '';
}


String _aidokuNumber(Object? value) {
  if (value is! num) return '';
  final double number = value.toDouble();
  if (number == number.truncateToDouble()) return number.toInt().toString();
  return number.toString().replaceFirst(RegExp(r'0+$'), '');
}

String? _aidokuHttpsUrl(Object? value) {
  final String candidate = value?.toString().trim() ?? '';
  return Uri.tryParse(candidate)?.isScheme('https') == true ? candidate : null;
}
