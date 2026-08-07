// jidoujisho 血统「UI 媒体源/标签页」体系的 barrel：MediaType / MediaSource
// 抽象 + reader/dictionary 类型 + 各 reader 源实现（页面经 package:fushi/media.dart
// 消费）。
//
// 「来源库」域（src/media/source_library/：SourceLibraryScanner /
// SourceLibraryCredentialStore / SourceFileSystem / SourceLibraryRow，TODO-817
// 扫描根）刻意**不**经本 barrel 导出——它与上面的 UI MediaSource 概念语义无关
// （命名红线见 source_library/source_file_system.dart 头注释），且会把网络/IO 依赖
// 拖进 UI 源注册；消费侧与 audiobook/ video/ torrent/ 等子域同一原则，直接
// import 'src/media/source_library/...'。

export 'src/media/media_item.dart';
export 'src/media/media_source.dart';
export 'src/media/media_type.dart';

export 'src/media/types/dictionary_media_type.dart';
export 'src/media/types/reader_media_type.dart';

export 'src/media/sources/reader_media_source.dart';
export 'src/media/sources/reader_hibiki_source.dart';
export 'src/media/sources/reader_pdf_source.dart';
export 'src/media/sources/manga_hibiki_source.dart';

export 'src/media/video/video_immersive_mode.dart';
