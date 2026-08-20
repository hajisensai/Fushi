import 'package:path/path.dart' as p;

/// 书籍扩展名（不带点，小写）。= epub + TextToEpub.supportedExtensions。
const Set<String> kDragBookExtensions = <String>{
  'epub',
  'txt',
  'html',
  'htm',
  'xhtml',
  'md',
  'markdown',
  'rst',
  'org',
  'csv',
  'tsv',
  'log',
  'json',
  'xml',
};

/// 字幕扩展名（不带点，小写）。
const Set<String> kDragSubtitleExtensions = <String>{
  'srt',
  'vtt',
  'ass',
  'ssa',
  'lrc',
};

/// 视频扩展名（不带点，小写）。镜像 [kVideoExtensions]（media_extensions.dart
/// 共享真相源，文件夹扫描 / 刮削同用一份），守卫测试钉死两者同步——否则拖入
/// .mts/.vob/.rmvb 等容器格式的视频会被分到 unknown，识别不出（TODO-558 / BUG-326）。
const Set<String> kDragVideoExtensions = <String>{
  'mp4',
  'mkv',
  'avi',
  'mov',
  'webm',
  'm4v',
  'ts',
  'm2ts',
  'mts',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ogv',
  'rmvb',
  'rm',
  'vob',
};

/// 播放列表扩展名（不带点，小写）。扩展 M3U（m3u8/m3u）= 多集视频清单，语义不同于
/// 单个视频文件：拖入后走 [parseM3u8] 解析成 playlist VideoBook（多集 + 各集进度），
/// 不能当单视频导入。故单列一类，与 [kDragVideoExtensions] 区分。
const Set<String> kDragPlaylistExtensions = <String>{
  'm3u8',
  'm3u',
};

/// 词典包扩展名（不带点，小写）。= 词典管理页文件选择器实际能导入的格式
/// （Yomitan/Migaku/mdict/dsl 的 zip + 裸 .dsl/.mdx），见 DictionaryImportManager
/// 的 detectFormat。`.ifo`/`.css` 不在此列：前者非独立导入单位、后者是随词典的样式
/// 附件（拖单个 css 不构成一次导入）。词典拖放是词典管理页专属落点，与书架/视频
/// 表面（books/video）互不影响，故 .zip 在此被识别为词典包而非 unknown。
const Set<String> kDragDictionaryExtensions = <String>{
  'zip',
  'dsl',
  'mdx',
};

/// 漫画扩展名（不带点，小写）：**明确**的漫画载体，落点表面一见即知。
///
/// - `mokuro`：mokuro v0.2+ 的 OCR 结果文件（+ 同级图片），走 `MangaImporter`；
/// - `cbz`：图片压缩包，走 `MangaArchiveImporter`。
///
/// 不含 `zip`：它同时是词典包扩展名，光看扩展名分不出「一包页图」还是 Yomitan
/// 词典包，故走 [kDragImageArchiveProbeExtensions] + `isImageArchive` 注入判据。
///
/// 也不含 `epub`：图片型 EPUB（扫描版漫画）确实存在，但它在 books 分支就走
/// `importNewBook` → `BookImportDialog`，而对话框的分派本来就会真读包
/// （`{'.zip','.epub'} && MangaModule.isImageArchive` → `importArchive`），最终
/// 照样导成漫画——行为已经正确。为它在**每次拖 EPUB** 时白开一次包换不来任何
/// 可见改进，不值得。
const Set<String> kDragMangaExtensions = <String>{
  'mokuro',
  'cbz',
};

/// 需要**真读包内容**才能定性的容器扩展名（不带点，小写）。
///
/// 只含 `zip`：它既可能是页图漫画包，也可能是 Yomitan/mdict 词典包。没有判据时
/// 分类层只能按扩展名归 dictionaries，于是**图片型 zip 拖到书架/漫画库会回「本
/// 页面不支持」**（books 分支走到 `files.hasAny` 兜底），而导入对话框导得了它——
/// 又一处「按钮能导、拖进去不认」。判据由调用方注入（widget 层传
/// `MangaModule.isImageArchive`，即 `MangaArchiveImporter.looksLikeImageArchive`），
/// 分类层自身仍不碰文件系统；判据缺席时 zip 维持词典包分类，向后兼容。
const Set<String> kDragImageArchiveProbeExtensions = <String>{
  'zip',
};

/// 看得出是漫画包、但当前**导入器不支持**的扩展名（不带点，小写）。
///
/// `archive` 包不解 RAR，故 cbr/cb7/rar 无法导入。单列一类只为一件事：让落点
/// 给出明确的「不支持」提示，而不是归进 unknown 后静默无反应（用户实报「拖进去
/// 一点反应都没有」）。
const Set<String> kDragUnsupportedMangaExtensions = <String>{
  'cbr',
  'cb7',
  'rar',
};

/// 音频扩展名（不带点，小写）。镜像 AudiobookStorage.audioExtensions（守卫测试钉死同步）。
const Set<String> kDragAudioExtensions = <String>{
  'mp3',
  'm4a',
  'm4b',
  'aac',
  'ogg',
  'opus',
  'flac',
  'wav',
  'wma',
  'ac3',
  'eac3',
  'mp4',
};

/// 拖入文件按扩展名分类的结果。一个路径可同时落入多个类（如 .mp4 既是视频又是音频），
/// 由落点上下文（DropSurface）决定最终语义。
class DroppedFiles {
  const DroppedFiles({
    required this.books,
    required this.videos,
    required this.subtitles,
    required this.audios,
    required this.playlists,
    required this.dictionaries,
    required this.urls,
    required this.unknown,
    this.mangas = const <String>[],
    this.unsupportedMangas = const <String>[],
    this.directories = const <String>[],
  });

  final List<String> books;
  final List<String> videos;
  final List<String> subtitles;
  final List<String> audios;
  final List<String> playlists;
  final List<String> dictionaries;

  /// 漫画载体：`.mokuro` / `.cbz`，以及被 [classifyDroppedFiles] 的 `isDirectory`
  /// 谓词判定为**目录**的路径（整目录页图导入，manga_importer 的
  /// `importFromImageFolder` 路径）。
  final List<String> mangas;

  /// 认得出是漫画包但导入器不支持的（cbr/cb7/rar，见
  /// [kDragUnsupportedMangaExtensions]）——落点据此给明确提示而非静默。
  final List<String> unsupportedMangas;

  /// 被 `isDirectory` 谓词判定为**目录**的路径，作为**事实**原样记录。
  ///
  /// 与 [mangas] 是交叠而非互斥的：目录同时也会进 [mangas]，保住书架/漫画库既有的
  /// 「整目录页图导入一本漫画」。分开记的理由是——「这是个目录」是事实，「目录算漫画」
  /// 是判断，判断必须留给知道落点表面的 [decideDropIntent] 去做。此前事实被就地
  /// 编码成判断，于是视频页永远拿不到「用户拖进来的是个文件夹」这个信息。
  final List<String> directories;

  /// 拖入的可导入网络流 URL（http(s)，非文件路径）。浏览器地址栏/链接拖进来时，
  /// 原生（Windows CFSTR_INETURLW / macOS public.url / Linux text/uri-list）把 URL
  /// 当作一个「路径」字符串经同一通道传回，[classifyDroppedFiles] 按 scheme 从文件
  /// 路径中甄别出来落到本类（TODO-1306），由落点决策路由到流媒体导入 [_importStreamUrl]。
  final List<String> urls;

  final List<String> unknown;

  /// 是否有任何可被本功能识别（非 unknown）的文件。
  bool get hasAny =>
      books.isNotEmpty ||
      videos.isNotEmpty ||
      subtitles.isNotEmpty ||
      audios.isNotEmpty ||
      playlists.isNotEmpty ||
      dictionaries.isNotEmpty ||
      urls.isNotEmpty ||
      mangas.isNotEmpty ||
      unsupportedMangas.isNotEmpty;
}

String _ext(String path) {
  final String e = p.extension(path); // 含前导点，如 ".EPUB"
  if (e.isEmpty) return '';
  return e.substring(1).toLowerCase();
}

/// 纯函数：判断拖入的字符串是否是一条可导入的网络流 URL（http/https + 非空 host）。
///
/// 语义与 `isPlayableStreamUrl`（url_stream_video.dart）钉死同步（守卫测试
/// `url_drop_url_predicate_guard_test`），是「拖入的这条字符串到底是文件路径还是可
/// 导入 URL」的单一判据：Windows 盘符路径 `C:\a.mp4` 的 scheme 会被解析成 `c`、UNC /
/// POSIX 路径 scheme 为空，均非 http(s) → 判为文件路径，不会误吞。纯字符串判定，不碰
/// 文件系统 / 网络（TODO-1306）。
bool isImportableDropUrl(String candidate) {
  final Uri? uri = Uri.tryParse(candidate.trim());
  if (uri == null) return false;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

/// 把拖入文件路径按扩展名分类。纯函数，无副作用。
///
/// [isDirectory] 是唯一的外注入判据：拖入的**目录**（漫画页图文件夹）没有扩展名，
/// 纯扩展名分类无法与「无扩展名的文件」区分，而本函数不碰文件系统。调用方
/// （widget 层）传 `(pth) => Directory(pth).existsSync()`，测试注入假谓词。
/// 不传（默认 null）时行为与历史逐字节一致——目录会落进 [DroppedFiles.unknown]。
DroppedFiles classifyDroppedFiles(
  List<String> paths, {
  bool Function(String path)? isDirectory,
  bool Function(String path)? isImageArchive,
}) {
  final List<String> books = <String>[];
  final List<String> videos = <String>[];
  final List<String> subtitles = <String>[];
  final List<String> audios = <String>[];
  final List<String> playlists = <String>[];
  final List<String> dictionaries = <String>[];
  final List<String> urls = <String>[];
  final List<String> mangas = <String>[];
  final List<String> unsupportedMangas = <String>[];
  final List<String> directories = <String>[];
  final List<String> unknown = <String>[];

  for (final String path in paths) {
    // URL（浏览器地址栏/链接拖入）不是文件路径，先按 scheme 甄别，命中即归 urls 并
    // 跳过扩展名分类——URL 即便末段带 `.mp4` 也交给流媒体导入而非当本地文件（TODO-1306）。
    if (isImportableDropUrl(path)) {
      urls.add(path.trim());
      continue;
    }
    // 目录（漫画页图文件夹）：整目录导入一本漫画。放在扩展名分类之前——目录名
    // 带点时（如 `第01巻.v2`）会被 p.extension 当成扩展名而误分类。
    if (isDirectory != null && isDirectory(path)) {
      directories.add(path);
      mangas.add(path);
      continue;
    }
    final String ext = _ext(path);
    bool matched = false;
    // 图片包（`.zip`）：光看扩展名与词典包同形，必须真读包——同 isDirectory，判据
    // 由 widget 层注入。命中即**只**归 mangas（不再落 dictionaries），否则图片型
    // zip 会走到 books 分支的 `files.hasAny` 兜底、回「本页面不支持」，而导入对话框
    // 明明导得了它。与对话框同一判据，两条入口的回答因此必然一致。
    if (isImageArchive != null &&
        kDragImageArchiveProbeExtensions.contains(ext) &&
        isImageArchive(path)) {
      mangas.add(path);
      continue;
    }
    if (kDragMangaExtensions.contains(ext)) {
      mangas.add(path);
      matched = true;
    }
    if (kDragUnsupportedMangaExtensions.contains(ext)) {
      unsupportedMangas.add(path);
      matched = true;
    }
    if (kDragBookExtensions.contains(ext)) {
      books.add(path);
      matched = true;
    }
    if (kDragVideoExtensions.contains(ext)) {
      videos.add(path);
      matched = true;
    }
    if (kDragPlaylistExtensions.contains(ext)) {
      playlists.add(path);
      matched = true;
    }
    if (kDragSubtitleExtensions.contains(ext)) {
      subtitles.add(path);
      matched = true;
    }
    if (kDragAudioExtensions.contains(ext)) {
      audios.add(path);
      matched = true;
    }
    if (kDragDictionaryExtensions.contains(ext)) {
      dictionaries.add(path);
      matched = true;
    }
    if (!matched) unknown.add(path);
  }

  return DroppedFiles(
    books: books,
    videos: videos,
    subtitles: subtitles,
    audios: audios,
    playlists: playlists,
    dictionaries: dictionaries,
    urls: urls,
    mangas: mangas,
    unsupportedMangas: unsupportedMangas,
    directories: directories,
    unknown: unknown,
  );
}

/// 词典管理页拖放专用分类：从拖入路径里挑出词典包（`.zip`/`.dsl`/`.mdx`）以及同批
/// 拖入的 `.css` 样式附件，按「先词典包后 css」拼成可直接喂给词典导入器的路径列表。
/// 纯函数，无副作用，便于单测。无词典包时返回空列表（即便夹带了 css 也不导入——
/// 单独拖个 css 不构成一次导入，与文件选择器 [_importDictionaryFiles] 同语义）。
List<String> classifyDroppedFilesForDictionary(List<String> paths) {
  final DroppedFiles files = classifyDroppedFiles(paths);
  if (files.dictionaries.isEmpty) return const <String>[];
  final List<String> cssAttachments = paths
      .where((String pth) => p.extension(pth).toLowerCase() == '.css')
      .toList();
  return <String>[...files.dictionaries, ...cssAttachments];
}

/// 给一个视频挑配对字幕：按**文件名主干**（不含扩展名）大小写不敏感匹配，
/// 找不到返回 null。
///
/// 多个视频一起拖入时用它逐个配对——把同一条字幕挂到每一集比不挂更糟。单个视频
/// 的历史行为（直接取第一条字幕）由调用方保留，不走这里。
String? subtitleForVideoByStem(String videoPath, List<String> subtitles) {
  final String stem = p.basenameWithoutExtension(videoPath).toLowerCase();
  for (final String subtitle in subtitles) {
    if (p.basenameWithoutExtension(subtitle).toLowerCase() == stem) {
      return subtitle;
    }
  }
  return null;
}
