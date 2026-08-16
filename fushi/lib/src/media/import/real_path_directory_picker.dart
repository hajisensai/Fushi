import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, immutable, kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;

/// 真应用集成测试的目录选择结果注入；release 构建恒忽略。
@visibleForTesting
String? debugRealDirectoryPathOverride;

/// 「选一个文件夹并返回它的**真实文件系统绝对路径**」的统一入口。
///
/// 为什么不直接到处调 `FilePicker.getDirectoryPath()`：在安卓上 file_picker 的
/// `getDirectoryPath()` 返回的是 tree content URI 解析出的字符串，对受保护目录还
/// 会退化成 `/` 或不可用路径。下游 `listVideoFilesInDirectory` / sidecar 扫描 /
/// 封面 / 制卡 / 播放全是 `dart:io` 真实路径语义，content URI 串喂进去恒空
/// （TODO-949 的根因）。
///
/// 安卓改为：先确保 `MANAGE_EXTERNAL_STORAGE`（全文件访问）→ 调**系统原生 SAF**
/// 目录选择器（`ACTION_OPEN_DOCUMENT_TREE`，原生 handler 见 MainActivity 的
/// `pickRealDirectory`）→ 原生用 `DocumentsContract` 把 tree URI 解析回真实绝对
/// 路径。app 持全文件访问，`dart:io` 可直接读该真实路径，下游全部不变。
/// **桌面 / iOS 维持 `getDirectoryPath()`**（它们本就返回真实路径）。
///
/// 只有 externalstorage provider（设备存储/SD 卡）能映射出真实路径；云盘/虚拟
/// provider 无真实路径 → 原生返回 null → 这里取消（与旧自绘浏览器同样不可达，无退化）。
///
/// [dialogTitle] / [initialDirectory] 只对桌面 / iOS 的 `getDirectoryPath()` 生效
/// （原样透传）。安卓走系统 SAF（`ACTION_OPEN_DOCUMENT_TREE`），标题与初始目录由
/// 系统自己决定，两个参数被忽略——这不是退化，是 SAF 本来就不接受这两项。
Future<String?> pickRealDirectoryPath({
  required BuildContext context,
  required AppModel appModel,
  String? dialogTitle,
  String? initialDirectory,
}) async {
  if (kDebugMode && debugRealDirectoryPathOverride != null) {
    return debugRealDirectoryPathOverride;
  }
  // 桌面（Windows/macOS/Linux）与 iOS：`getDirectoryPath()` 已返回真实路径。
  if (defaultTargetPlatform != TargetPlatform.android) {
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
    );
  }

  // 安卓：先确保 MANAGE_EXTERNAL_STORAGE（全文件访问）已授权——下游 dart:io 读盘需要。
  await appModel.requestExternalStoragePermissions();
  final bool granted =
      await appModel.platformServices.permission.hasExternalStoragePermission();
  if (!granted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.folder_picker_permission_required)),
      );
    }
    return null;
  }

  // 原生 SAF 目录选择器 → 原生把 tree URI 解析成真实绝对路径（不复制）。
  return _pickRealPathViaSaf('pickRealDirectory');
}

/// 「选一个**文件**并返回它的真实文件系统绝对路径」的统一入口（board 1112）。
///
/// 与 [pickRealDirectoryPath] 同源同哲学，只是叶子是文件而非目录：安卓上
/// `FilePicker.pickFiles()` 会把选中文件**复制一份到 app cache** 再返回缓存路径
/// ——手机存储/IO 差时白拷一份大视频，且清缓存后该路径失效、videoPath 引用悬空。
/// 视频导入本就只存绝对路径不复制（见 video_import_dialog），这个缓存副本是唯一
/// 残留的「变相复制」。
///
/// 授予 `MANAGE_EXTERNAL_STORAGE`（全文件访问）后，`dart:io` 可全盘读真实路径，
/// 于是安卓改为：先确保权限 → 调**系统原生 SAF** 文件选择器
/// （`ACTION_OPEN_DOCUMENT`，原生 handler 见 MainActivity 的 `pickRealFile`）→
/// 原生把 document URI 解析回真实绝对路径 → 返回真实绝对路径，不产生任何副本。
///
/// **降级逃生口**：安卓未授予全文件访问时，回退到 `FilePicker.pickFiles()`（仍复制到
/// cache，但功能可用）——不硬性要求授权。**桌面 / iOS 维持 `pickFiles()`**（它们本就
/// 返回真实路径、不复制）。
///
/// [allowedExtensions] 为不带点的小写扩展名集（如 `{'srt','ass'}`）；null = 不过滤
/// （任意文件，用于视频）。原生 SAF 选到的文件若带过滤集，则按扩展名在 Dart 端校验。
Future<String?> pickRealFilePath({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  try {
    final PickedFilePath? picked = await pickRealFilePathDetailed(
      context: context,
      appModel: appModel,
      allowedExtensions: allowedExtensions,
    );
    return picked?.path;
  } on PickedFileWithoutPathException {
    // 本入口的既有契约是「拿不到就返回 null」，既有调用方并不 catch。
    // 想区分「取消」与「选了但没 path」的调用方改用 [pickRealFilePathDetailed]。
    return null;
  }
}

/// 平台交回了条目、却没有一条带可用路径（部分平台只回 bytes 不回 path）。
///
/// 与「用户取消」必须区分（BUG-446）：取消是静默返回，这个是**失败**，调用方要记
/// 诊断并给用户可见反馈。压成同一个 null 就等于把一类失败伪装成一次取消。
class PickedFileWithoutPathException implements Exception {
  const PickedFileWithoutPathException({required this.count});

  /// 平台交回的条目数（用于诊断日志）。
  final int count;

  @override
  String toString() => 'PickedFileWithoutPathException(count: $count)';
}

/// 一次文件选择的结果：路径 **+ 这条路径是不是用户原始位置的真实路径**。
///
/// 为什么需要它（BUG-1667）：「选到的文件能不能长期引用」此前是调用点**按平台猜**的
/// ——本地音频库导入的「引用原文件不复制」开关直接写死 `isDesktopPlatform`，理由是
/// 「移动端 file_picker 给的是会被系统清掉的缓存临时副本」。可 [pickRealFilePath]
/// 落地后，安卓拿到全文件访问就走 SAF 解析真实路径、根本不产生副本，那条平台前提
/// 就不成立了。**平台不是判据，路径的出处才是**：把出处随路径一起返回，调用方按
/// 事实决策，「安卓一律不能引用」这个特例随之消失。
@immutable
class PickedFilePath {
  const PickedFilePath({required this.path, required this.isRealPath});

  /// 选中文件的绝对路径。
  final String path;

  /// true = 用户原始位置的真实路径，可被长期引用（桌面 / iOS 的 `pickFiles()`、
  /// 安卓授予全文件访问后的 SAF 解析）。
  ///
  /// false = file_picker 在安卓复制出来的 **app cache 临时副本**
  /// （`FileUtils.openFileStream` 把整份文件同步拷进 `getCacheDir()/file_picker/`）。
  /// 清缓存即失效，**只能立刻复制消费，不能作为长期引用落库**。
  final bool isRealPath;
}

/// [pickRealFilePath] 的带出处版本：除路径外还告诉调用方这条路径能不能长期引用。
/// 平台分流、权限处理、降级逃生口与 [pickRealFilePath] 完全一致（后者现在只是丢掉
/// 出处的薄封装），差别只在返回类型。
Future<PickedFilePath?> pickRealFilePathDetailed({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  // 桌面（Windows/macOS/Linux）与 iOS：`pickFiles()` 已返回真实路径、不复制。
  if (defaultTargetPlatform != TargetPlatform.android) {
    return _detailedFallback(
      context: context,
      allowedExtensions: allowedExtensions,
      isRealPath: true,
    );
  }

  // 安卓：先尝试确保 MANAGE_EXTERNAL_STORAGE（全文件访问）已授权。
  await appModel.requestExternalStoragePermissions();
  final bool granted =
      await appModel.platformServices.permission.hasExternalStoragePermission();
  if (!granted) {
    // 降级逃生口：无全文件访问权限时回退 file_picker（仍复制到 cache 但可用）。
    // 这条路径是 cache 临时副本，出处必须如实标 false——调用方据此禁掉引用。
    if (!context.mounted) return null;
    return _detailedFallback(
      context: context,
      allowedExtensions: allowedExtensions,
      isRealPath: false,
    );
  }

  // 原生 SAF 文件选择器 → 原生解析真实绝对路径（不复制到 cache）。
  final String? realPath = await _pickRealPathViaSaf('pickRealFile');
  if (realPath == null) return null; // 取消 / 云盘虚拟 provider（同旧浏览器不可达）
  if (allowedExtensions == null || allowedExtensions.isEmpty) {
    return PickedFilePath(path: realPath, isRealPath: true);
  }
  // 带扩展名过滤：原生 SAF 不做扩展名限制，在 Dart 端按集合校验并提示。
  final List<String> accepted = _filterPickedFilesByExtension(
    context: context.mounted ? context : null,
    paths: <String>[realPath],
    allowedExtensions: _normalizeExtensions(allowedExtensions),
  );
  return accepted.isEmpty
      ? null
      : PickedFilePath(path: accepted.first, isRealPath: true);
}

/// [pickRealFilePathDetailed] 的 file_picker 回退分支（桌面 / iOS，以及安卓未授予
/// 全文件访问时的逃生口）：把「取消」「选了但平台没给 path」「扩展名全被过滤」三种
/// 空结果区分开，只有第二种是失败（抛 [PickedFileWithoutPathException]）。
Future<PickedFilePath?> _detailedFallback({
  required BuildContext context,
  required bool isRealPath,
  Set<String>? allowedExtensions,
}) async {
  final _RawPickResult raw = await _fallbackPickRaw(
    context: context,
    allowMultiple: false,
    allowedExtensions: allowedExtensions,
  );
  if (raw.rawCount == 0) return null; // 用户取消：静默。
  if (raw.paths.isEmpty) {
    // 平台交回了条目却没有可用 path = 失败，必须可见（BUG-446）。
    if (raw.missingPathCount > 0) {
      throw PickedFileWithoutPathException(count: raw.rawCount);
    }
    return null; // 扩展名全被过滤掉：过滤处已弹提示，这里静默。
  }
  return PickedFilePath(path: raw.paths.first, isRealPath: isRealPath);
}

/// 调原生 SAF 选择器并返回真实绝对路径；null = 用户取消，或云盘/虚拟 provider
/// 无法映射真实路径。[method] 为 `'pickRealDirectory'`（目录）或 `'pickRealFile'`
/// （文件），对应 MainActivity 的 SAF channel handler。
Future<String?> _pickRealPathViaSaf(String method) async {
  try {
    return await FushiChannels.saf.invokeMethod<String>(method);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 「选一个文件、走系统文件选择器（安卓 SAF / iOS Files / 桌面原生），返回其路径」。
///
/// 与 [pickRealFilePath] 的分工：[pickRealFilePath] 面向**以绝对路径长期引用、导入时
/// 不复制**的文件（视频——SAF 复制到 cache 的路径清缓存即悬空，故安卓改真实路径）。
/// 而字幕 / 对齐文件（smil/srt/lrc/vtt/ass/json…）在导入时即被解析成 cues / 生成
/// EPUB / 跑 matcher **当场消费**，SAF 复制到 cache 的临时副本读完即弃，不存在悬空问题。
/// 因此这类文件维持系统文件选择器：用户熟悉，且能触达 Downloads / 云盘 / 最近文件等
/// 位置（board 1360——用户报「导入选字幕文件的选择器变了」）。
///
/// 安卓不需要 `MANAGE_EXTERNAL_STORAGE`（SAF 自带授权），桌面 / iOS 本就返回真实路径。
/// [allowedExtensions] 为不带点的小写扩展名集；iOS 的 `.srt` 等 UTI 解析问题由
/// [_fallbackPickFile] 内部统一处理（先 `FileType.any` 打开 Files，再按扩展名校验）。
Future<String?> pickSystemFilePath({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) =>
    _fallbackPickFile(context: context, allowedExtensions: allowedExtensions);

/// 「选多个文件并返回真实文件系统绝对路径」。
///
/// 多选走 file_picker。iOS 上不能使用 file_picker 的 audio 类型，它会打开
/// `MPMediaPickerController`（资料库）而不是 Files；带扩展名过滤的入口统一由
/// [_fallbackPickFiles] 处理。
///
/// 🔴 **每条返回路径都必须是可增长（growable）的 [List]**，包括「用户取消」「页面已
/// 销毁」这类空结果。调用方（有声书导入 / 书导入 / 阅读器补音频 / 书架重新定位 SRT
/// 音频）拿到列表后**先就地 `sort` 再判空**——而 Dart 的编译期常量列表是
/// `UnmodifiableListMixin`，它的 `sort` **无条件抛 `UnsupportedError`，空列表照抛**
/// （不是「非空才抛」）。BUG-1574 的用户崩溃就是取消文件选择器时返回不可变空列表，
/// 在 `_pickSrtAudioFiles` 的 `paths.sort(...)` 处炸掉。
/// 这里省下的那一次空列表分配，换来的是四个调用点各自加一圈判空补丁——别改回去。
Future<List<String>> pickRealFilePaths({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    await appModel.requestExternalStoragePermissions();
  }
  if (!context.mounted) return <String>[];
  return _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
  );
}

/// 回退到 file_picker 选单个文件（安卓无全文件访问 / 桌面 / iOS）。
Future<String?> _fallbackPickFile({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) async {
  final List<String> paths = await _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
  );
  return paths.isEmpty ? null : paths.single;
}

/// 回退到 file_picker 选文件。iOS 对 `.srt` 等扩展名的 UTI 解析可能返回 dyn.*，
/// 传给 `FileType.custom` 后会被原生插件丢弃；因此 iOS 先用 `FileType.any`
/// 打开 Files，再按扩展名做 Dart 端校验。
Future<List<String>> _fallbackPickFiles({
  required BuildContext context,
  required bool allowMultiple,
  Set<String>? allowedExtensions,
}) async =>
    (await _fallbackPickRaw(
      context: context,
      allowMultiple: allowMultiple,
      allowedExtensions: allowedExtensions,
    ))
        .paths;

/// [_fallbackPickRaw] 的返回：过滤后的可用路径 + 平台**原始**交回情况。
///
/// 为什么要留原始情况（BUG-446 / BUG-1667）：「用户取消」与「选了文件但平台没给
/// path」（部分平台只回 bytes）都会让 [paths] 为空，可两者的正确处理完全相反——
/// 前者静默返回，后者是失败必须让用户看见。把它们压成同一个空列表，就等于把一类
/// 失败伪装成一次取消。
class _RawPickResult {
  const _RawPickResult({
    required this.paths,
    required this.rawCount,
    required this.missingPathCount,
  });

  /// 扩展名过滤后的可用绝对路径。
  final List<String> paths;

  /// 平台交回的条目数（含没有 path 的）；0 = 用户取消。
  final int rawCount;

  /// 交回的条目里没有 path 的条目数（部分平台只回 bytes）。
  final int missingPathCount;
}

Future<_RawPickResult> _fallbackPickRaw({
  required BuildContext context,
  required bool allowMultiple,
  Set<String>? allowedExtensions,
}) async {
  final Set<String> normalizedExtensions =
      _normalizeExtensions(allowedExtensions);
  final bool filterAfterPick = defaultTargetPlatform == TargetPlatform.iOS &&
      normalizedExtensions.isNotEmpty;

  final FilePickerResult? result;
  if (filterAfterPick || normalizedExtensions.isEmpty) {
    result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: allowMultiple,
    );
  } else {
    result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: normalizedExtensions.toList(),
      allowMultiple: allowMultiple,
    );
  }

  // 不写 `const <PlatformFile>[]`：本文件按 BUG-1574 的纪律一律不产出不可变集合
  // （守卫 real_path_picker_growable_test 整文件盲扫）。这里虽是不外传的局部中间量，
  // 但「省一次空分配」正是那条纪律要挡掉的诱惑，不给下一个人留反例。
  final List<PlatformFile> files = result?.files ?? <PlatformFile>[];
  final int rawCount = files.length;
  final int missingPathCount =
      files.where((PlatformFile f) => f.path == null).length;
  // 取消（`result == null`）时同样返回可增长空列表：调用方会就地 sort（见
  // [pickRealFilePaths] 的说明）。`.toList()` 本身已是可增长的。
  final List<String> paths =
      files.map((PlatformFile file) => file.path).whereType<String>().toList();

  List<String> accepted = paths;
  if (filterAfterPick) {
    // 页面若在原生文件选择器打开期间被销毁，仍按扩展名做纯过滤返回，只是无法
    // 弹「不支持格式」提示（context 传 null，过滤逻辑不依赖 context）。
    accepted = _filterPickedFilesByExtension(
      context: context.mounted ? context : null,
      paths: paths,
      allowedExtensions: normalizedExtensions,
    );
  }
  return _RawPickResult(
    paths: accepted,
    rawCount: rawCount,
    missingPathCount: missingPathCount,
  );
}

Set<String> _normalizeExtensions(Set<String>? extensions) {
  // 同上：本文件不向外交出不可变集合（零特例，省得下一个消费方 add 时再炸一次）。
  if (extensions == null || extensions.isEmpty) return <String>{};
  return extensions
      .map((String ext) => ext.toLowerCase().replaceFirst('.', ''))
      .where((String ext) => ext.isNotEmpty)
      .toSet();
}

List<String> _filterPickedFilesByExtension({
  required BuildContext? context,
  required List<String> paths,
  required Set<String> allowedExtensions,
}) {
  final List<String> accepted = <String>[];
  final List<String> rejected = <String>[];
  for (final String path in paths) {
    final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (allowedExtensions.contains(ext)) {
      accepted.add(path);
    } else {
      rejected.add(path);
    }
  }
  if (rejected.isNotEmpty && context != null && context.mounted) {
    final String ext = p.extension(rejected.first).toLowerCase();
    FushiToast.show(
      msg: t.import_unsupported_file_format(
        ext: ext.isEmpty ? p.basename(rejected.first) : ext,
      ),
      severity: ToastSeverity.error,
    );
  }
  return accepted;
}
