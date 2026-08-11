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

/// 播放列表清单扩展名（扩展 M3U）：**文本清单，不是媒体流本体**。app 侧对它的
/// 唯一正确动作是 `parseM3u8` 拆成各集；直接把本地清单文件喂 ffmpeg 抽帧必然
/// `Invalid data found when processing input`（BUG-1564：封面回填曾如此反复
/// 白烧 CPU）。与 [kVideoExtensions] 两两不相交（扫描/拖放分类依赖该不相交性）。
///
/// 注意边界：**远端** `http(s)://…/x.m3u8` 是 HLS 流 URL，ffmpeg 能直接吃
/// （见 `streamImportCoverStrategy.ffmpegFrame`）——本集合只用于判定**本地文件**。
const Set<String> kPlaylistManifestExtensions = <String>{
  '.m3u8',
  '.m3u',
};
