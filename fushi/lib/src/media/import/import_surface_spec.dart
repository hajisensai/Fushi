/// 导入界面拼贴（导入稿 v2「〇、判据与共用组件」）的数据层：六个模块（书 / 漫画 /
/// 视频 / 音乐 / 游戏 / 查词空态）套同一组组件，只换这一份 [ImportSurfaceSpec]。
///
/// - 取色有出处（稿「取色表」R11）：模块色 [ImportTone] 钉在 [ImportSurfaceSpec.tone]，
///   方式块按 [ImportMethodKind] 钉色（跨模块同一种方式同色），主方式取模块色反色；
/// - 方式按规范顺序声明（主方式 → 导入文件夹 → 其他 → 网络共享），组件不再重排
///   （IM1：旧快速导入区把次按钮重排成 [last, ...middle]，书的顺序被排反）；
/// - 格式从导入器真认的扩展名集合派生（[importFormatLabels]），网络说明从
///   [importNetworkTransports] 派生（IM10：副标题与真实传输不符）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart'
    show FileDropCallback;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';

/// 把各域的扩展名真相源集合（带不带点均可）派生成「支持格式」文案：去点、转大写、
/// 按给出顺序去重（如 `.mp4` 同时在视频与音频集合里）。
///
/// 格式必须从导入实际认的集合派生，不许再手写子集——手写的那份会和导入器静默漂移
/// （漫画页曾只写 CBZ/ZIP/PDF/MOKURO/JPG/PNG，实际还认 CBR/CB7/RAR/EPUB 与
/// WEBP/GIF/BMP 等）。
List<String> importFormatLabels(Iterable<Iterable<String>> extensionSets) {
  final Set<String> labels = <String>{};
  for (final Iterable<String> extensions in extensionSets) {
    for (final String extension in extensions) {
      final String bare = extension.startsWith('.')
          ? extension.substring(1)
          : extension;
      if (bare.isNotEmpty) labels.add(bare.toUpperCase());
    }
  }
  return labels.toList(growable: false);
}

/// 导入稿取色表的七个色（t1–t7），按色相给出，配色统一走
/// [FushiCoverBlockColors.fromHue]（与拼贴色块同一套 HSL，深浅两套主题都可读）。
///
/// 色相取自稿中深色底色 `--c` 的 HSL 色相。
enum ImportTone {
  /// t1：音乐模块色；IPTV、有声书方式。
  rose(327.7),

  /// t2：视频模块色；下载推荐词典方式。
  cyan(196.2),

  /// t3：漫画模块色；音频 CD 方式。
  violet(257.4),

  /// t4：游戏模块色；粘贴文本方式。
  amber(45),

  /// t5：文件夹类方式（导入文件夹 / 扫描文件夹 / 文件夹词典）。
  green(140),

  /// t6：书模块色；光盘方式。
  coral(18.3),

  /// t7：查词模块色；网络共享方式、互联块。
  indigo(229);

  const ImportTone(this.hue);

  final double hue;
}

/// [tone] 此刻的块配色；[inverse] 取反色（主方式块：底用强调色、字用底色）。
///
/// 墨水屏退成主题中性色（与拼贴色块同一口径），反色在墨水屏上是前景 / 底色互换。
FushiCoverBlockColors importToneColors(
  BuildContext context,
  ImportTone tone, {
  bool inverse = false,
}) {
  final ThemeData theme = Theme.of(context);
  final FushiCoverBlockColors base = isEinkTheme(context)
      ? FushiCoverBlockColors.resolve(theme, null)
      : FushiCoverBlockColors.fromHue(theme, tone.hue);
  if (!inverse) return base;
  return FushiCoverBlockColors(
    container: isEinkTheme(context) ? base.onContainer : base.accent,
    onContainer: base.container,
    accent: base.container,
    watermarkOpacity: base.watermarkOpacity,
  );
}

/// 向导入面子树广播本模块的模块色：来源区（[MediaSourcesView] 的色块呈现）、
/// 「添加来源」块的悬停描边等不必一层层传参。没有这一层时取 [fallback]。
class ImportToneScope extends InheritedWidget {
  const ImportToneScope({required this.tone, required super.child, super.key});

  final ImportTone tone;

  static ImportTone of(
    BuildContext context, {
    ImportTone fallback = ImportTone.indigo,
  }) =>
      context.dependOnInheritedWidgetOfExactType<ImportToneScope>()?.tone ??
      fallback;

  @override
  bool updateShouldNotify(ImportToneScope oldWidget) => oldWidget.tone != tone;
}

/// 方式的类型：决定方式块的钉色（稿「取色表」第二行），跨模块一致。
enum ImportMethodKind {
  /// 主方式（导入书 / 导入漫画 / 导入视频 / 添加音乐文件夹 / 添加游戏 / 导入词典）：
  /// 模块色反色。一个 spec 只放一个，且必须排第一。
  primary,

  /// 文件夹类（导入文件夹 / 扫描文件夹 / 导入文件夹词典）：t5。
  folder,

  /// 网络共享：t7。
  network,

  /// 粘贴文本：t4。
  pasteText,

  /// IPTV 频道列表：t1。
  iptv,

  /// 光盘（DVD / BD / ISO）：t6。
  disc,

  /// 音频 CD：t3。
  audioCd,

  /// 下载推荐词典：t2。
  recommendedDictionary,

  /// 有声书（IM15）：t1。
  audiobook,
}

/// 方式块的钉色；主方式由调用方取模块色反色（见 [ImportMethodBlock]）。
ImportTone importMethodTone(ImportMethodKind kind, ImportTone moduleTone) =>
    switch (kind) {
      ImportMethodKind.primary => moduleTone,
      ImportMethodKind.folder => ImportTone.green,
      ImportMethodKind.network => ImportTone.indigo,
      ImportMethodKind.pasteText => ImportTone.amber,
      ImportMethodKind.iptv => ImportTone.rose,
      ImportMethodKind.disc => ImportTone.coral,
      ImportMethodKind.audioCd => ImportTone.violet,
      ImportMethodKind.recommendedDictionary => ImportTone.cyan,
      ImportMethodKind.audiobook => ImportTone.rose,
    };

/// 方式块右下角「去向」：点下去会发生什么（稿 `.mb .go`）。只在中宽以上显示。
enum ImportDestination {
  /// 打开导入对话框。
  dialog,

  /// 先二选一（导入文件夹：常驻来源 / 仅此一次）。
  choice,

  /// 登记为常驻来源（网络共享）。
  source,

  /// 存好直接打开阅读（粘贴文本）。
  read,

  /// 直接弹系统选文件。
  pickFile,

  /// 直接弹系统选目录。
  pickFolder,

  /// 选光驱。
  pickDrive,

  /// 打开推荐列表。
  list,
}

/// 一种导入方式（一个方式块）。
@immutable
class ImportMethod {
  const ImportMethod({
    required this.id,
    required this.kind,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
    this.destination,
    this.note,
    this.reportsProgress = false,
    this.enabled = true,
  });

  /// 稳定 id：块的 key 是 `ValueKey('import-method-$id')`，焦点 id 同名。
  final String id;
  final ImportMethodKind kind;
  final IconData icon;

  /// 方式名（块名称，17→13 装盒，永不省略号截断）。
  final String label;

  /// 一句说明（中宽以上显示；手机只留名称 + 去向箭头）。
  final String? description;

  /// 去向（中宽以上显示在块底）。
  final ImportDestination? destination;

  /// 说明下的附注（如视频「导入文件夹」在 Windows / macOS 上的音频 CD 提示，IM16）。
  final String? note;

  /// 这条流程**不弹对话框**（选 .exe、选目录、粘贴保存）：跑的时候本块转圈、
  /// 说明换「导入中…」、其余方式块压暗不可点（IM14）。弹对话框的方式进度看
  /// 对话框自己的分步文案，块上不画。
  final bool reportsProgress;

  final bool enabled;

  /// 入口动作；Future 结束 = 流程结束（[reportsProgress] 的转圈据此收起）。
  final Future<void> Function() onTap;
}

/// 「支持 n 种格式」气泡里的一组（组名来自扩展名集合本身，标签由
/// [importFormatLabels] 派生，不手写）。
@immutable
class ImportFormatGroup {
  const ImportFormatGroup({required this.title, required this.labels});

  final String title;
  final List<String> labels;
}

/// 一个导入面的全部差异（六个模块各填一份，组件不按模块分支）。
@immutable
class ImportSurfaceSpec {
  const ImportSurfaceSpec({
    required this.id,
    required this.tone,
    required this.guideIcon,
    required this.guideTitle,
    required this.guideDescription,
    required this.methods,
    this.guideDescriptionWithoutDrop,
    this.formatGroups = const <ImportFormatGroup>[],
    this.pickOnlyFormatGroups = const <ImportFormatGroup>[],
    this.onDrop,
  }) : assert(methods.length > 0, 'an import surface needs a method');

  /// 模块 id（'book' / 'manga' / 'video' / 'music' / 'game' / 'dictionary'），
  /// 用于 key 与拖放日志标签。
  final String id;

  /// 模块色：引导首块底色、主方式块反色、「添加来源」块悬停描边。
  final ImportTone tone;

  /// 引导首块多边形里的图标。
  final IconData guideIcon;

  /// 引导首块标题（「把 X 放进库里」）。
  final String guideTitle;

  /// 引导首块说明（桌面能拖放时用，可以提「拖进这一页」）。
  final String guideDescription;

  /// 没有拖放时（移动端 / iOS / 本面不收拖放）的说明，不提拖放；null 时沿用
  /// [guideDescription]（说明本来就不提拖放的模块）。
  final String? guideDescriptionWithoutDrop;

  /// 按规范顺序：主方式 → 导入文件夹 → 其他 → 网络共享。
  final List<ImportMethod> methods;

  /// 拖放 + 选文件都认的格式组；全部为空时不画「支持 n 种格式」。
  final List<ImportFormatGroup> formatGroups;

  /// 只在选文件时另外支持的格式组（查词：StarDict）。
  final List<ImportFormatGroup> pickOnlyFormatGroups;

  /// 整页落点的落下处理：交给该模块库页现有的 onDrop（不另写分发，IM2）。
  /// null = 本面不收拖放：不装落点、不画虚线框、不进拖放态。
  final FileDropCallback? onDrop;

  /// 「支持 n 种格式」的 n（两类格式组合并去重）。
  int get formatCount => <String>{
    for (final ImportFormatGroup g in formatGroups) ...g.labels,
    for (final ImportFormatGroup g in pickOnlyFormatGroups) ...g.labels,
  }.length;

  /// 来源区第一个块的错峰序号：0 引导首块 → 1..n 方式块 → n+1 区头 → 来源块。
  int get sourceEntranceIndex => methods.length + 2;
}

/// 本域网络来源可选的传输（唯一真相源，`_NetworkSourceFormDialog` 的协议分段
/// 与「网络共享」说明都从这里派生，IM10）：
/// - 书 / 漫画：SFTP / FTP / WebDAV / AList（远端文件下载后导入）；
/// - 视频 / 音乐：SFTP / WebDAV / AList（原地流播 / 按区间读标签；FTP 读不了区间，
///   扫描器会拒）；
/// - 游戏：没有网络来源（exe 要在本机拉起）。
List<String> importNetworkTransports(String mediaKind) => switch (mediaKind) {
  'game' => const <String>[],
  'video' || 'music' => const <String>['sftp', 'webdav', 'alist'],
  _ => const <String>['sftp', 'ftp', 'webdav', 'alist'],
};

/// 传输 id 的显示名（协议名不翻译）。
String importNetworkTransportLabel(String transport) => switch (transport) {
  'sftp' => 'SFTP',
  'ftp' => 'FTP',
  'alist' => 'AList',
  _ => 'WebDAV',
};

/// 「网络共享」块 / 「添加来源 › 网络」的说明：按本域真实传输派生，
/// 如 `SFTP · WebDAV · AList`。
String importNetworkTransportsSummary(String mediaKind) =>
    importNetworkTransports(
      mediaKind,
    ).map(importNetworkTransportLabel).join(' · ');
