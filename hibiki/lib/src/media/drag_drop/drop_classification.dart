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

/// 视频扩展名（不带点，小写）。镜像 [kVideoExtensions]（video_filename_parser.dart，
/// 文件夹扫描用的权威列表），守卫测试钉死两者同步——否则拖入 .mts/.vob/.rmvb 等容器
/// 格式的视频会被分到 unknown，识别不出（TODO-558 / BUG-326）。
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
    required this.unknown,
  });

  final List<String> books;
  final List<String> videos;
  final List<String> subtitles;
  final List<String> audios;
  final List<String> playlists;
  final List<String> dictionaries;
  final List<String> unknown;

  /// 是否有任何可被本功能识别（非 unknown）的文件。
  bool get hasAny =>
      books.isNotEmpty ||
      videos.isNotEmpty ||
      subtitles.isNotEmpty ||
      audios.isNotEmpty ||
      playlists.isNotEmpty ||
      dictionaries.isNotEmpty;
}

String _ext(String path) {
  final String e = p.extension(path); // 含前导点，如 ".EPUB"
  if (e.isEmpty) return '';
  return e.substring(1).toLowerCase();
}

/// 把拖入文件路径按扩展名分类。纯函数，无副作用。
DroppedFiles classifyDroppedFiles(List<String> paths) {
  final List<String> books = <String>[];
  final List<String> videos = <String>[];
  final List<String> subtitles = <String>[];
  final List<String> audios = <String>[];
  final List<String> playlists = <String>[];
  final List<String> dictionaries = <String>[];
  final List<String> unknown = <String>[];

  for (final String path in paths) {
    final String ext = _ext(path);
    bool matched = false;
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
