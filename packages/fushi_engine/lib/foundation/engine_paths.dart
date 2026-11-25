/// 引擎侧数据根目录装配点。
///
/// app 的 `AppPaths`（path_provider + shared_preferences）是各根目录的唯一真相源；
/// 引擎只需要三个根（documents / support / temp），子目录名是引擎与 app 共同的
/// 契约（`video_covers` / `video_subtitles` …），所以派生方法放在这里、实现方只
/// 提供三个根：
/// - Flutter app：`AppPathsEngineBridge`，三个根委派 `AppPaths.*RootDirectory()`。
/// - 无头服务端：配置文件里的 `data_dir` 下 `documents/` / `support/` / `tmp/`。
///
/// 未装配就调用是编程错误（[UninstalledEnginePaths] 直接抛），不做静默兜底：
/// 落错目录比抛异常更难查。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

abstract class EnginePaths {
  const EnginePaths();

  /// 内容/书库根（等价 `getApplicationDocumentsDirectory()`）。
  Future<Directory> documentsRootDirectory();

  /// 数据库/模型根（等价 `getApplicationSupportDirectory()`）。
  Future<Directory> supportRootDirectory();

  /// 临时目录（等价 `getTemporaryDirectory()`）。
  Future<Directory> tempRootDirectory();

  /// `<documents>/<child>` 的绝对路径目录（不创建）。与 `AppPaths.documentsSubdirectory`
  /// 同派生规则，保证两边对同一子目录名拿到逐字节一致的路径。
  Future<Directory> documentsSubdirectory(String child) async {
    final Directory root = await documentsRootDirectory();
    return Directory(p.join(root.path, child));
  }

  /// 视频封面目录 `<documents>/video_covers`。
  Future<Directory> videoCoversDirectory() =>
      documentsSubdirectory('video_covers');

  /// 视频外挂字幕副本目录 `<documents>/video_subtitles`。
  Future<Directory> videoSubtitlesDirectory() =>
      documentsSubdirectory('video_subtitles');

  /// EPUB 解压正文根 `<documents>/fushi_books`。
  Future<Directory> epubBooksDirectory() =>
      documentsSubdirectory('fushi_books');

  /// 有声书音频持久根 `<documents>/audiobooks`。
  Future<Directory> audiobooksDirectory() =>
      documentsSubdirectory('audiobooks');

  /// 系统文件选择器把用户选中的文件**拷进** app 沙盒时落盘的目录（BUG-2863）。
  ///
  /// 这些目录里的媒体文件不是用户的原件，而是 app 为了能读到它才复制出来的整份
  /// 副本：iOS 的 file_picker 以 `UIDocumentPickerModeImport` 打开，选中的视频被
  /// 搬进容器 `tmp/`（`NSTemporaryDirectory()`），库里 `videoPath` 存的就是这份
  /// 副本。删库条目时它们与封面、字幕副本一样属于 app 自有资产，必须回收——否则
  /// 「删了视频还占储存」。
  ///
  /// 默认只有 [pickedVideoCopiesDirectory]：选择器交回的临时副本在落库前已被挪进
  /// 那里（BUG 见 `adoptPickedVideoCopy`），它和 iOS `tmp/` 一样是 app 自有副本。
  /// 桌面 / Android SAF 解析成功时选择器给的是用户真实路径，根本不进这个目录。
  Future<List<Directory>> pickerImportCopyDirectories() async => <Directory>[
    await pickedVideoCopiesDirectory(),
  ];

  /// 选择器临时副本的持久落点 `<support>/imported_videos`（不创建）。
  ///
  /// iOS file_picker 的 import 模式把选中视频放进 `NSTemporaryDirectory()`，安卓
  /// 无全文件访问 / provider 解析不出真实路径时放进 app cache——两处都会被系统或
  /// `FilePicker.clearTemporaryFiles()` 清空。要长期引用的视频必须在落库前挪到
  /// 这里，`videoPath` 才不会过一阵变成「找不到文件」。
  Future<Directory> pickedVideoCopiesDirectory() async {
    final Directory root = await supportRootDirectory();
    return Directory(p.join(root.path, 'imported_videos'));
  }
}

/// 固定根目录实现（服务端 / 测试用）。
class FixedEnginePaths extends EnginePaths {
  const FixedEnginePaths({
    required this.documents,
    required this.support,
    required this.temp,
  });

  final Directory documents;
  final Directory support;
  final Directory temp;

  @override
  Future<Directory> documentsRootDirectory() async => documents;

  @override
  Future<Directory> supportRootDirectory() async => support;

  @override
  Future<Directory> tempRootDirectory() async => temp;
}

class UninstalledEnginePaths extends EnginePaths {
  const UninstalledEnginePaths();

  Never _fail() => throw StateError(
    'enginePaths not installed: the host process must assign '
    'fushi_engine `enginePaths` before touching storage.',
  );

  @override
  Future<Directory> documentsRootDirectory() async => _fail();

  @override
  Future<Directory> supportRootDirectory() async => _fail();

  @override
  Future<Directory> tempRootDirectory() async => _fail();
}

/// 全局装配点。宿主进程入口写一次。
EnginePaths enginePaths = const UninstalledEnginePaths();
