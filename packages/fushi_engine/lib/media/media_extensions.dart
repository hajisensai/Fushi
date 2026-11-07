/// 媒体文件扩展名共享真相源（小写、含点）。
///
/// 此前图片 / 视频扩展名白名单在仓内多处各自手写整表，彼此静默漂移——典型即
/// BUG-1121：漫画导入认 `.bmp`（manga_importer.dart），整卷 OCR 白名单却没有
/// `.bmp`（manga_ocr_folder_job.dart）→ bmp 页被静默跳过、OCR 产物缺页无提示。
///
/// 收敛规则：本文件只放**基集 / 共享表**；各消费方引用后按自身语义**显式增删**
/// 差异项并注释理由，禁止再各自手写整表。纯常量、零依赖，任何层（后台 isolate /
/// 测试）都可安全引用。
library;

/// 图片扩展名基集：主流位图格式，解码端（`package:image` 的 `decodeImage`
/// 内容嗅探 / Flutter codec）均支持。
///
/// const Set 字面量按书写顺序迭代——顺序即「按序取用」场景（如视频 sidecar
/// 海报候选）的优先序：越常见越靠前。
const Set<String> kImageExtensionsBase = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

/// 漫画页图扩展名：基集 + `.avif`。导入（`kMangaImageExtensions`）与整卷 OCR
/// （`kMangaOcrImageExtensions`）两道关卡共用这一张（BUG-1121：两表漂移 = 某格式页
/// OCR 静默缺页）。
///
/// `.avif` 不进基集：基集承诺「Flutter codec 也能解」，而 AVIF 只有原生内核
/// （`decodeImageNative`，native/fushi_compute 的 image/avif.rs）与 WebView 认。漫画页
/// 正文在 WebView 里显示，尺寸 / OCR / 裁图走原生内核，封面 / 缩略图走 app 侧的
/// 原生解码 ImageProvider，所以漫画能收；视频海报、游戏封面等还直接交给 Flutter
/// codec 的消费方不能收。
const Set<String> kMangaPageImageExtensions = <String>{
  ...kImageExtensionsBase,
  '.avif',
};

/// 视频文件扩展名：导入 / 文件夹扫描 / torrent 选片 / 刮削剥扩展名共用一份
/// （G10 第一步——此前刮削端 `FilenameParser` 另手写一张只有 9 项的小表，
/// `.rmvb` 等能导入的格式在刮削时剥不掉、扩展名留在标题里拉低搜索相似度）。
const Set<String> kVideoExtensions = <String>{
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.m4v',
  '.ts',
  '.m2ts',
  '.mts',
  '.flv',
  '.wmv',
  '.mpg',
  '.mpeg',
  '.ogv',
  '.rmvb',
  '.rm',
  '.vob',
};

/// 纯音频文件扩展名（专辑曲目 / 广播剧 / 有声内容等**无画面**媒体）。
///
/// = 音乐扫描器认的扩展名（`native/fushi_music/src/tags.rs` 的 `AUDIO_EXTENSIONS`）去掉
/// `.mp4` 再加点号，守卫测试 `fushi/test/build/music_audio_extensions_rust_parity_guard_test.dart`
/// 读 Rust 表钉死同步：这里判成纯音频、交给音乐库的文件，音乐库必须收得下（两表不一致
/// 时，视频来源里的 `.m4b` 曾被分流出视频库、音乐扫描又不认，两个库里都没有它）。
///
/// 与 [kVideoExtensions] 两两不相交：`.mp4` 虽然也可能只装音轨，但它首先是视频
/// 容器，归视频。**包含**（不等于）`AudiobookStorage.audioExtensions` 去掉 `.mp4`：有声书
/// 播放器是 just_audio（Android 上是 ExoPlayer），解不了 ape / dsf / tta / wv / mka 等，
/// 有声书素材表不跟着扩；音乐播放走 libmpv，这些都能播。
///
/// **纯音频不进视频库**（用户 2026-11-06 拍板，反馈 QAondMh4M5：广播剧 CD 的
/// mp3 / flac 出现在视频库）：视频库的入库与对账（来源扫描、拖放、服务端扫描 /
/// 对账枚举）只认 [kVideoExtensions]；视频来源里扫到的纯音频交给音乐库
/// （`fushi/lib/src/media/music/music_audio_intake.dart`）。「是不是纯音频」全仓
/// 只经 [isAudioOnlyMediaPath] 判，各入口不另抄一份。
const Set<String> kAudioExtensions = <String>{
  '.flac',
  '.m4a',
  '.m4b',
  '.alac',
  '.mp3',
  '.mp2',
  '.mpa',
  '.ogg',
  '.oga',
  '.opus',
  '.wav',
  '.aiff',
  '.aif',
  '.aifc',
  '.ape',
  '.wv',
  '.tak',
  '.tta',
  '.mpc',
  '.dsf',
  '.dff',
  '.aac',
  '.ac3',
  '.eac3',
  '.ec3',
  '.mka',
  '.caf',
  '.w64',
  '.wma',
};

/// 纯函数：[path] 是否是纯音频文件（按扩展名，大小写不敏感，不碰文件系统）。
///
/// 远端 URL 带查询串时取路径段的扩展名。
bool isAudioOnlyMediaPath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return false;
  final Uri? uri = Uri.tryParse(trimmed);
  final String candidate =
      uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
      ? uri.path
      : trimmed;
  final int slash = candidate.lastIndexOf(RegExp(r'[\\/]'));
  final String name = candidate.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0) return false;
  return kAudioExtensions.contains(name.substring(dot).toLowerCase());
}

/// 播放列表清单扩展名（扩展 M3U）：**文本清单，不是媒体流本体**。app 侧对它的
/// 唯一正确动作是 `parseM3u8` 拆成各集；直接把本地清单文件喂 ffmpeg 抽帧必然
/// `Invalid data found when processing input`（BUG-1564：封面回填曾如此反复
/// 白烧 CPU）。与 [kVideoExtensions] 两两不相交（扫描/拖放分类依赖该不相交性）。
///
/// 注意边界：**远端** `http(s)://…/x.m3u8` 是 HLS 流 URL，ffmpeg 能直接吃
/// （见 `streamImportCoverStrategy.ffmpegFrame`）——本集合只用于判定**本地文件**。
const Set<String> kPlaylistManifestExtensions = <String>{'.m3u8', '.m3u'};
