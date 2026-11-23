import 'dart:async' show unawaited;
import 'dart:io' show Directory;

import 'package:material_ui/material_ui.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/drag_drop/book_archive_probe.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:fushi/src/media/drag_drop/image_archive_probe.dart';
import 'package:fushi/src/media/import/book_archive_import_dialog.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 书架 / 漫画库的拖放路由：分类 → 命中测试 → 决策 → 打开对应对话框 / 提示。
///
/// 书架（`_ReaderFushiHistoryPageState`）与书 / 漫画的「导入」视图
/// （`BookImportPage` / `MangaSourcesPage`）共用这一份分发：两处落点对同一批文件
/// 给出同一个结果（IM2——导入视图此前画着拖放虚线却没有落点，而书架那份分发又是
/// 书架 State 的私有方法，导入视图拿不到）。
///
/// [context] 是落点所在子树的 context：await 之后一律用 `context.mounted` 判活。
/// [hitTestCard] 是书卡登记表的命中测试（Flutter global 坐标 → bookKey）；导入视图
/// 没有书卡，传 null（音频 / 字幕单独拖入时给「拖到某本书上」的提示）。
/// [onLibraryChanged] 在书 / 漫画落库后调用（宿主自己失效书架 provider）；
/// [onAudiobookAttached] 在往书卡上挂完有声书后调用。
Future<void> routeReaderShelfDrop({
  required BuildContext context,
  required AppModel appModel,
  required bool mangaOnly,
  required List<String> paths,
  required Offset globalPosition,
  required VoidCallback onLibraryChanged,
  String? Function(Offset globalPosition)? hitTestCard,
  VoidCallback? onAudiobookAttached,
  String debugLabel = 'reader-shelf',
}) async {
  final ModalRoute<dynamic>? route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return;

  // 图片型 .zip（一包页图的漫画）与 Yomitan 词典包同形，要真读包才分得出——与导入
  // 对话框的分派同一判据，两条入口对「这算不算漫画」回答一致。但那次「真读包」是
  // **同步解整个压缩包**，原来就长在下面 classifyDroppedFiles 的注入谓词里，也就
  // 长在 desktop_drop 回调的同步栈上：拖个大包进来 UI 线程直接卡死。先离线程一次
  // 性判完（[probeDroppedImageArchives]），再把结果当同步谓词喂回去，分类函数保持
  // 纯函数不变。
  //
  // 漫画库（[mangaOnly]）落点偏好漫画：`.epub` 也开包，图片型 EPUB 直接归漫画，
  // 不再先进书籍导入框、再被告知「这看起来是漫画」；`.pdf` 直接归漫画。
  final Map<String, bool> imageArchives = await probeDroppedImageArchives(
    paths,
    preferManga: mangaOnly,
    db: appModel.database,
  );
  // 装着一批书的 `.zip` / `.rar`（一包 EPUB / TXT 小说合集）同样要看包里装的是什么：
  // 页图包已由上一步归漫画，剩下的再看条目名（拍板 83Fe7zQbhv）。
  final Map<String, bool> bookArchives = await probeDroppedBookArchives(
    paths,
    imageArchives: imageArchives,
  );
  if (!context.mounted) return;

  // 目录（漫画页图文件夹）没有扩展名，纯分类函数分不出来——把真实文件系统判据
  // 注入进去（分类层本身仍不碰 IO）。
  final DroppedFiles files = classifyDroppedFiles(
    paths,
    isDirectory: (String pth) => Directory(pth).existsSync(),
    isImageArchive: (String pth) => imageArchives[pth] ?? false,
    isBookArchive: (String pth) => bookArchives[pth] ?? false,
    preferManga: mangaOnly,
  );
  debugPrint(
    '[fushi-drop] [$debugLabel] classified '
    'books=${files.books.length} subtitles=${files.subtitles.length} '
    'audios=${files.audios.length} videos=${files.videos.length} '
    'mangas=${files.mangas.length} bookArchives=${files.bookArchives.length} '
    'unsupportedMangas=${files.unsupportedMangas.length} '
    'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length} '
    'global=$globalPosition',
  );
  final String? hitBookKey = hitTestCard?.call(globalPosition);
  // 漫画库是同一个页面的 mangaOnly 壳，但落点语义不同（见 DropSurface.manga）。
  final DropIntent intent = decideDropIntent(
    surface: mangaOnly ? DropSurface.manga : DropSurface.books,
    files: files,
    cardHit: hitBookKey != null,
  );
  // 跨模块落点一次快照。被关掉的模块不再打开它的导入对话框，而是给一条与
  // [DropIntent.unsupportedSurface] 同形态的 SnackBar——拖放没有「不渲染入口」
  // 这个选项（落点就是整块书架），所以必须给可见反馈，绝不静默吞掉。
  final ModuleVisibility modules = appModel.moduleVisibility;
  void showSnack(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  void showModuleDisabled() => showSnack(t.module_disabled_hint);

  final _ReaderShelfDropActions actions = _ReaderShelfDropActions(
    context: context,
    appModel: appModel,
    onLibraryChanged: onLibraryChanged,
  );

  switch (intent) {
    // 书架/漫画库不产出这个意图：目录在这两个表面仍是「一本漫画的页图文件夹」
    // （importNewManga），把整个目录登记成扫描根是视频页的语义。列出来只为让
    // `decideDropIntent` 以后给 books 也加上文件夹语义时，这里编译期就红。
    case DropIntent.addFolderAsSource:
      debugPrint(
        '[fushi-drop] [$debugLabel] intent=addFolderAsSource '
        '(not produced on this surface)',
      );
    case DropIntent.importNewBook:
      // 一本书：同批的字幕 / 音频一起预填（有声书）。多本：逐本弹导入框，不再只导
      // 第一本、其余静默丢掉；此时字幕 / 音频没法确定归哪一本，不预填。
      if (files.books.length == 1) {
        unawaited(
          actions.openBookImportPrefilled(
            epubPath: files.books.single,
            subtitlePath: files.subtitles.isNotEmpty
                ? files.subtitles.first
                : null,
            audioPaths: files.audios,
          ),
        );
      } else {
        unawaited(actions.openBookImportsInSequence(files.books));
      }
    case DropIntent.importNewManga:
      // 漫画（.mokuro / .cbz / 页图目录 / 图片型 zip）走漫画自己的导入对话框。
      // 决策层本来就把漫画和书分成了两个 intent，此前两个 intent 却落到同一个
      // 对话框；现在落点跟着 intent 走，载体身份不再在半路丢失。
      if (!modules.isEnabled(ModuleId.manga)) {
        showModuleDisabled();
        return;
      }
      unawaited(actions.openMangaImportPrefilled(mangaPaths: files.mangas));
    case DropIntent.importBookArchive:
      // 一包书 / 列不出名字的包（.7z、分卷第一卷）：解开一次按内容分流——书整批导入给一份
      // 汇总，只有页图的交漫画导入（漫画模块关着时汇总里如实说明）。同批拖入的单本书一起
      // 交进去，不静默丢掉。
      unawaited(
        actions.openBookArchiveImport(<String>[
          ...files.bookArchives,
          ...files.books,
        ]),
      );
    case DropIntent.unsupportedMangaArchive:
      debugPrint('[fushi-drop] [$debugLabel] intent=unsupportedMangaArchive');
      showSnack(t.drag_drop_manga_archive_unsupported);
    case DropIntent.attachToBookCard:
      // 往书卡上拖音频/字幕 = 给这本书挂有声书，属听书模块。
      if (!modules.isEnabled(ModuleId.listening)) {
        showModuleDisabled();
        return;
      }
      unawaited(
        actions.openAudiobookPrefilled(
          bookKey: hitBookKey!,
          audioPaths: files.audios,
          alignmentPath: files.subtitles.isNotEmpty
              ? files.subtitles.first
              : null,
          onAttached: onAudiobookAttached,
        ),
      );
    case DropIntent.needCardTarget:
      debugPrint('[fushi-drop] [$debugLabel] intent=needCardTarget');
      showSnack(t.drag_drop_need_card_target);
    case DropIntent.importNewVideo:
      // 书架拖入视频 → 自动切到视频导入流程，带上文件（不再只提示让用户手动切，
      // TODO-558）。
      if (!modules.isEnabled(ModuleId.video)) {
        showModuleDisabled();
        return;
      }
      unawaited(
        actions.openVideoImport(
          initialVideoPath: files.videos.first,
          initialSubtitlePath: files.subtitles.isNotEmpty
              ? files.subtitles.first
              : null,
        ),
      );
    case DropIntent.importNewPlaylist:
      if (!modules.isEnabled(ModuleId.video)) {
        showModuleDisabled();
        return;
      }
      unawaited(
        actions.openVideoImport(initialPlaylistPath: files.playlists.first),
      );
    case DropIntent.importVideoUrl:
      // 书架拖入网络流 URL → 自动切到视频导入（预填 URL 并入库），与拖视频文件的
      // 自动切换一致（TODO-1306）。
      if (!modules.isEnabled(ModuleId.video)) {
        showModuleDisabled();
        return;
      }
      unawaited(actions.openVideoImport(initialStreamUrl: files.urls.first));
    case DropIntent.importTorrent:
      // 拖入 .torrent → 下载中心「添加任务」对话框预填种子；内容类型按落点预填
      // （漫画库→漫画、书架→小说），用户可在框里改。下载中心是独立模块，关掉
      // 时与其它模块一样给可见提示而不是静默。
      if (!modules.isEnabled(ModuleId.browse)) {
        showModuleDisabled();
        return;
      }
      unawaited(
        showManualDownloadTaskDialog(
          context: context,
          appModel: appModel,
          torrentPaths: files.torrents,
          initialDiscoveryKind: mangaOnly
              ? DiscoveryMediaKind.manga
              : DiscoveryMediaKind.novel,
        ),
      );
    case DropIntent.unsupportedSurface:
      debugPrint('[fushi-drop] [$debugLabel] intent=unsupportedSurface');
      showSnack(t.drag_drop_unsupported_on_books);
    case DropIntent.attachToVideoCard:
    // 只由 video 表面产出（书架上的音频是有声书素材），列在此处仅为穷尽 switch。
    case DropIntent.importAudioToMusic:
    case DropIntent.ignore:
      break;
  }
}

/// 落点决策之后打开的各个预填对话框（书 / 漫画 / 有声书 / 视频）。
class _ReaderShelfDropActions {
  const _ReaderShelfDropActions({
    required this.context,
    required this.appModel,
    required this.onLibraryChanged,
  });

  final BuildContext context;
  final AppModel appModel;
  final VoidCallback onLibraryChanged;

  /// 拖入书文件 → 打开 [BookImportDialog]，预填 EPUB（及可选字幕 / 音频）路径。
  ///
  /// 返回对话框结果：true 已导入、false 这一本没导（同名取消 / 转交漫画未导）、
  /// null 用户关掉了对话框（[openBookImportsInSequence] 据此停止后续）。
  Future<bool?> openBookImportPrefilled({
    required String epubPath,
    required String? subtitlePath,
    List<String> audioPaths = const <String>[],
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        prefs: appModel.prefsRepo,
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialEpubPath: epubPath,
        initialSubtitlePath: subtitlePath,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
      ),
    );
    if (imported == true && context.mounted) onLibraryChanged();
    return imported;
  }

  /// 多本书同时拖入：逐本打开 [BookImportDialog]（每本都要定标题 / 处理同名）。
  ///
  /// 只有用户**关掉对话框**（取消 / 返回键 / 点遮罩，结果 null）才停止后续：那是
  /// 「剩下的都不要了」。同名询问里选「否」只是这一本不导（对话框回 false），继续下一本
  /// ——否则一本重名就把后面所有书静默丢掉，正是这里要消灭的行为。
  Future<void> openBookImportsInSequence(List<String> bookPaths) async {
    for (final String bookPath in bookPaths) {
      if (!context.mounted) return;
      final bool? imported = await openBookImportPrefilled(
        epubPath: bookPath,
        subtitlePath: null,
      );
      if (imported == null) return;
    }
  }

  /// 拖入装着一批书的压缩包 → 解包整批导入（[showBookArchiveImportDialog]），一份汇总；
  /// 解开是页图的包交漫画导入。
  Future<void> openBookArchiveImport(List<String> paths) async {
    final bool imported = await showBookArchiveImportDialog(
      context: context,
      db: appModel.database,
      paths: paths,
      importMangaDirectories:
          appModel.moduleVisibility.isEnabled(ModuleId.manga)
          ? (List<String> directories) => showMangaDirectoriesImportDialog(
              context: context,
              db: appModel.database,
              directories: directories,
            )
          : null,
    );
    if (imported && context.mounted) onLibraryChanged();
  }

  /// 拖入漫画 → 打开 [MangaImportDialog]，预填漫画路径（目录 / .cbz / .mokuro /
  /// 图片型 zip / 漫画库里的图片型 epub 与 pdf）。多个路径时对话框进逐卷批量模式。
  /// 漫画与书共用 `EpubBooks` 表和同一块书架，故落库后的刷新与书相同。
  Future<void> openMangaImportPrefilled({
    required List<String> mangaPaths,
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) =>
          MangaImportDialog(db: appModel.database, initialPaths: mangaPaths),
    );
    if (imported == true && context.mounted) onLibraryChanged();
  }

  /// 拖入字幕/音频到书卡 → 打开 [AudiobookImportDialog] 附加到该书，预填音频/对齐路径。
  Future<void> openAudiobookPrefilled({
    required String bookKey,
    required List<String> audioPaths,
    required String? alignmentPath,
    VoidCallback? onAttached,
  }) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!context.mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        prefs: appModel.prefsRepo,
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialAlignmentPath: alignmentPath,
      ),
    );
    if (context.mounted) onAttached?.call();
  }

  /// 拖入视频 / 播放列表 / 网络流 URL → 打开 [VideoImportDialog] 预填（导入后视频
  /// 归「视频」tab，书架不显示视频，故不刷新书架）。
  Future<void> openVideoImport({
    String? initialVideoPath,
    String? initialSubtitlePath,
    String? initialPlaylistPath,
    String? initialStreamUrl,
  }) async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: VideoBookRepository(appModel.database),
        initialVideoPath: initialVideoPath,
        initialSubtitlePath: initialSubtitlePath,
        initialPlaylistPath: initialPlaylistPath,
        initialStreamUrl: initialStreamUrl,
      ),
    );
  }
}
