/// 「横幅…」面板：给一个条目挑横版背景（详情页海报面板 / 首页系列色块读的那张
/// `item_images` backdrop）。
///
/// 面板本身与媒体种类无关：来源与写入全在 [BannerPickerTarget] 里——书 / 漫画由
/// `book_banner_sources.dart` 装配（在线 = AniList / MangaBaka 的系列横幅，书中 =
/// 漫画跨页 / EPUB 彩页）；视频作品（`video_banner_sources.dart`）、游戏
/// （`game_banner_sources.dart`）、书 / 游戏合集（`collection_banner_sources.dart`）
/// 各换一组来源与写入口。三个来源用分段切换（在线 / 书中 / 文件或链接），没给的
/// 来源不出分段。
///
/// 选中一张后：拿到本地文件（在线图先下载）→ 比 16:9 窄的图先进裁剪框框一块 16:9
/// （复用制卡的 [showCropImageDialog]），够宽的原样用 → 交给 [BannerPickerTarget.apply]
/// 写入（书的写入走 `ItemScrapeStore` 用户口径，上来源锁，之后刮削不覆盖）。
///
/// 设计系统：M3E 是 [FushiAlertDialog]；Apple（玻璃）经 [showAdaptiveDialogSurface]
/// 推成 macOS 档 sheet / iOS 档整页，外壳是 [FushiAppleSurfaceFrame]。分段、按钮、
/// 卡片、输入框都是双设计系统的公共件；候选网格错峰入场 + 悬停抬升 / 按压回弹。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:fushi_engine/media/metadata/image_download.dart'
    show downloadImageToTempFile;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_book_scan.dart'
    show bannerNeedsCrop, kBannerAspect;
import 'package:fushi/src/pages/implementations/crop_image_dialog_page.dart'
    show showCropImageDialog;
import 'package:fushi/src/reader/illustration_aspect_probe.dart'
    show ImagePixelSize, probeIllustrationSizes;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/adaptive/fushi_apple_surface.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/gallery_image_picker.dart'
    show pickGalleryImageFile;

/// 面板的三个来源（分段顺序即此顺序）。
enum BannerPickerSource { online, fromWork, fileOrLink }

/// 网格里的一张候选。
@immutable
class BannerCandidate {
  const BannerCandidate({
    required this.id,
    required this.preview,
    required this.resolve,
    this.label,
    this.width,
    this.height,
    this.sourceUrl,
  });

  /// 网格内唯一（测试与「正在应用」态按它认）。
  final String id;

  /// 网格预览（缩略图 / 按宽度降采样的本地图）。
  final ImageProvider preview;

  /// 取原图到本地文件（在线图下载到临时文件；书中图直接是书目录里的文件）。
  final Future<File> Function() resolve;

  /// 卡片角标（来源名 / 页号）。
  final String? label;

  /// 已知的原图尺寸（决定要不要裁剪）；null = 拿到文件后再量。
  final int? width;
  final int? height;

  /// 原图的远程地址（写入 `item_images.source_url`）；本地图为 null。
  final String? sourceUrl;
}

/// 面板的来源与写入口（与媒体种类无关的那一半在 [showBannerPickerSheet]）。
@immutable
class BannerPickerTarget {
  const BannerPickerTarget({
    this.fromWorkLabel,
    required this.apply,
    this.clear,
    this.current,
    this.currentUserChosen = false,
    this.loadOnline,
    this.loadFromWork,
    this.attribution,
    this.download = downloadImageToTempFile,
    this.pickFile = pickGalleryImageFile,
    this.crop,
    this.probeSize,
    this.onlineEmptyMessage,
    this.fromWorkEmptyMessage,
    this.fromWorkFailedMessage,
  }) : assert(
         loadFromWork == null || fromWorkLabel != null,
         'loadFromWork needs a fromWorkLabel',
       );

  /// 「书中」分段的名字（视频「片中」、合集「合集内」）；没有 [loadFromWork] 时可空。
  final String? fromWorkLabel;

  /// 写入用户选的图（[sourceUrl] = 在线图 / 链接的原地址）。
  final Future<void> Function(File file, {String? sourceUrl}) apply;

  /// 移除横幅；null = 不出「移除」（当前那张不是能在这里移除的：视频作品的刮削图
  /// 归作品图组管，这里只移除用户选的那张）。
  final Future<void> Function()? clear;

  /// 当前横幅；null = 没有（不出预览与「移除」）。
  final ImageProvider? current;

  /// 当前横幅是用户选的（重新刮削不覆盖）。
  final bool currentUserChosen;

  /// 在线候选；null = 不提供（「在线服务」模块关着 / 这种条目没有在线来源）。
  final Future<List<BannerCandidate>> Function()? loadOnline;

  /// 条目自身的图（书中页 / 彩页）；null = 不提供。
  final Future<List<BannerCandidate>> Function()? loadFromWork;

  /// 在线候选下方的署名（数据源许可要求）；null = 不显示。
  final String? Function(List<BannerCandidate> online)? attribution;

  /// 链接 / 在线图下载到临时文件。
  final Future<File> Function(String url) download;

  /// 系统选图；用户取消为 null。
  final Future<File?> Function() pickFile;

  /// 裁剪接缝（测试注入）；null = [showCropImageDialog]（锁 16:9）。取消为 null。
  final Future<File?> Function(BuildContext context, File file)? crop;

  /// 量图尺寸接缝（测试注入）；null = 后台 isolate 读文件头。
  final Future<ImagePixelSize?> Function(File file)? probeSize;

  /// 「在线」没有候选时的说明；null = 书的说法（先刮削资料好认出系列）。
  final String? onlineEmptyMessage;

  /// 「书中」（各媒体自己的那一段）没有候选 / 读失败时的说明；null = 书的说法。
  final String? fromWorkEmptyMessage;
  final String? fromWorkFailedMessage;

  List<BannerPickerSource> get sources => <BannerPickerSource>[
    if (loadOnline != null) BannerPickerSource.online,
    if (loadFromWork != null) BannerPickerSource.fromWork,
    BannerPickerSource.fileOrLink,
  ];
}

/// 弹出「横幅…」面板。返回横幅是否变了（换了 / 移除了）。
Future<bool> showBannerPickerSheet({
  required BuildContext context,
  required BannerPickerTarget target,
}) async {
  final bool? changed = await showAdaptiveDialogSurface<bool>(
    context: context,
    builder: (BuildContext context) => BannerPickerSheet(target: target),
  );
  return changed ?? false;
}

/// [showBannerPickerSheet] 的内容（公开给 widget 测试直接挂）。
class BannerPickerSheet extends StatefulWidget {
  const BannerPickerSheet({required this.target, super.key});

  final BannerPickerTarget target;

  @override
  State<BannerPickerSheet> createState() => _BannerPickerSheetState();
}

class _BannerPickerSheetState extends State<BannerPickerSheet> {
  late BannerPickerSource _source = widget.target.sources.first;
  final Map<BannerPickerSource, Future<List<BannerCandidate>>> _loads =
      <BannerPickerSource, Future<List<BannerCandidate>>>{};
  final TextEditingController _link = TextEditingController();

  /// 正在应用的候选 id（`file` / `link` / `remove` 是另外三个动作）；非 null 时
  /// 其余操作置灰，不并发写。
  String? _busy;
  bool _linkInvalid = false;

  BannerPickerTarget get _target => widget.target;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// 来源第一次被看到时才开始加载（在线来源要打网络，书中要扫书）。
  Future<List<BannerCandidate>> _load(BannerPickerSource source) =>
      _loads.putIfAbsent(source, () {
        final Future<List<BannerCandidate>> Function()? load = switch (source) {
          BannerPickerSource.online => _target.loadOnline,
          BannerPickerSource.fromWork => _target.loadFromWork,
          BannerPickerSource.fileOrLink => null,
        };
        return load?.call() ?? Future<List<BannerCandidate>>.value(const []);
      });

  Future<void> _run(String busyKey, Future<bool> Function() body) async {
    if (_busy != null) return;
    setState(() => _busy = busyKey);
    bool done = false;
    try {
      done = await body();
    } catch (e, stack) {
      ErrorLogService.instance.log('BannerPickerSheet.apply', e, stack);
      FushiToast.show(
        msg: '${t.media_banner_apply_failed}\n$e',
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted && !done) setState(() => _busy = null);
    }
    if (done && mounted) Navigator.of(context).pop(true);
  }

  /// 拿到文件 → 必要时裁 16:9 → 写入。用户在裁剪框取消返回 false（面板留着）。
  Future<bool> _applyFile(
    File file, {
    String? sourceUrl,
    int? width,
    int? height,
  }) async {
    ImagePixelSize? size = width != null && height != null
        ? (width: width, height: height)
        : null;
    size ??= await (_target.probeSize ?? _probeSize)(file);
    File chosen = file;
    if (size != null &&
        bannerNeedsCrop(width: size.width, height: size.height)) {
      if (!mounted) return false;
      final File? cropped = await (_target.crop ?? _cropDefault)(context, file);
      if (cropped == null) return false;
      chosen = cropped;
    }
    await _target.apply(chosen, sourceUrl: sourceUrl);
    FushiToast.show(msg: t.media_banner_applied);
    return true;
  }

  Future<void> _choose(BannerCandidate candidate) => _run(
    candidate.id,
    () async => _applyFile(
      await candidate.resolve(),
      sourceUrl: candidate.sourceUrl,
      width: candidate.width,
      height: candidate.height,
    ),
  );

  Future<void> _pickFile() => _run('file', () async {
    final File? file = await _target.pickFile();
    if (file == null) return false;
    return _applyFile(file);
  });

  Future<void> _useLink() async {
    final String raw = _link.text.trim();
    final Uri? uri = Uri.tryParse(raw);
    final bool valid =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    setState(() => _linkInvalid = !valid);
    if (!valid) return;
    await _run('link', () async {
      final File file = await _target.download(raw);
      return _applyFile(file, sourceUrl: raw);
    });
  }

  Future<void> _remove() => _run('remove', () async {
    await _target.clear?.call();
    FushiToast.show(msg: t.media_banner_removed);
    return true;
  });

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<BannerPickerSource> sources = _target.sources;
    final Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_target.current case final ImageProvider current) ...<Widget>[
          _CurrentBanner(image: current, userChosen: _target.currentUserChosen),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (sources.length > 1) ...<Widget>[
          KeyedSubtree(
            key: const ValueKey<String>('banner-picker-sources'),
            child: adaptiveSegmentedButton<BannerPickerSource>(
              context: context,
              segments: <ButtonSegment<BannerPickerSource>>[
                for (final BannerPickerSource s in sources)
                  ButtonSegment<BannerPickerSource>(
                    value: s,
                    label: Text(
                      _sourceLabel(s),
                      key: ValueKey<String>('banner-picker-source-${s.name}'),
                    ),
                  ),
              ],
              selected: <BannerPickerSource>{_source},
              onSelectionChanged: (Set<BannerPickerSource> next) {
                if (next.isEmpty) return;
                setState(() => _source = next.first);
              },
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        SizedBox(
          height: 340,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            child: KeyedSubtree(
              key: ValueKey<BannerPickerSource>(_source),
              child: _source == BannerPickerSource.fileOrLink
                  ? _buildFileOrLink(context)
                  : _buildCandidates(context, _source),
            ),
          ),
        ),
      ],
    );
    final Widget? remove = _target.current == null || _target.clear == null
        ? null
        : FushiTextButton(
            key: const ValueKey<String>('banner-picker-remove'),
            onPressed: _busy == null ? _remove : null,
            child: Text(t.media_banner_remove),
          );
    final Widget close = FushiTextButton(
      onPressed: () => Navigator.of(context).pop(false),
      child: Text(t.dialog_close),
    );
    final FushiAppleSurfaceForm? appleForm = FushiAppleSurfaceScope.maybeFormOf(
      context,
    );
    if (appleForm != null) {
      return FushiAppleSurfaceFrame(
        title: t.media_banner_title,
        actions: <Widget>[
          ?remove,
          if (appleForm == FushiAppleSurfaceForm.sheet) close,
        ],
        body: body,
      );
    }
    final double width = (MediaQuery.sizeOf(context).width - 80).clamp(
      280.0,
      640.0,
    );
    return FushiAlertDialog(
      title: Text(t.media_banner_title),
      content: SizedBox(width: width, child: body),
      actions: <Widget>[?remove, close],
    );
  }

  String _sourceLabel(BannerPickerSource source) => switch (source) {
    BannerPickerSource.online => t.media_banner_source_online,
    BannerPickerSource.fromWork => _target.fromWorkLabel ?? '',
    BannerPickerSource.fileOrLink => t.media_banner_source_file,
  };

  Widget _buildCandidates(BuildContext context, BannerPickerSource source) {
    return FutureBuilder<List<BannerCandidate>>(
      future: _load(source),
      builder:
          (BuildContext context, AsyncSnapshot<List<BannerCandidate>> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const FushiLoadingView();
            }
            if (snap.hasError) {
              return FushiPlaceholderMessage(
                key: ValueKey<String>('banner-picker-${source.name}-failed'),
                icon: FushiIcons.brokenImage,
                tone: FushiPlaceholderTone.error,
                message: source == BannerPickerSource.online
                    ? t.media_banner_online_failed
                    : _target.fromWorkFailedMessage ??
                          t.media_banner_book_failed,
                detail: '${snap.error}',
              );
            }
            final List<BannerCandidate> items =
                snap.data ?? const <BannerCandidate>[];
            if (items.isEmpty) {
              return FushiPlaceholderMessage(
                key: ValueKey<String>('banner-picker-${source.name}-empty'),
                icon: FushiIcons.image,
                message: source == BannerPickerSource.online
                    ? _target.onlineEmptyMessage ?? t.media_banner_online_empty
                    : _target.fromWorkEmptyMessage ?? t.media_banner_book_empty,
              );
            }
            final String? attribution = source == BannerPickerSource.online
                ? _target.attribution?.call(items)
                : null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: FushiEntranceScope(
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 240,
                            childAspectRatio: kBannerAspect,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                      itemCount: items.length,
                      itemBuilder: fushiStaggeredItemBuilder(
                        (BuildContext context, int index) => _CandidateTile(
                          candidate: items[index],
                          busy: _busy == items[index].id,
                          enabled: _busy == null,
                          onTap: () => unawaited(_choose(items[index])),
                        ),
                      ),
                    ),
                  ),
                ),
                if (attribution != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      attribution,
                      key: const ValueKey<String>('banner-picker-attribution'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            );
          },
    );
  }

  Widget _buildFileOrLink(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool idle = _busy == null;
    return FushiEntranceScope(
      child: ListView(
        primary: false,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiFilledButton(
                key: const ValueKey<String>('banner-picker-file'),
                onPressed: idle ? () => unawaited(_pickFile()) : null,
                child: _busy == 'file'
                    ? const _InlineProgress()
                    : Text(t.media_banner_file_pick),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.section),
          FushiStaggeredEntrance(
            index: 1,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: FushiTextFieldControl(
                    key: const ValueKey<String>('banner-picker-link'),
                    controller: _link,
                    enabled: idle,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.media_banner_link_hint,
                      errorText: _linkInvalid
                          ? t.media_banner_link_invalid
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_useLink()),
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                FushiFilledButton(
                  key: const ValueKey<String>('banner-picker-link-use'),
                  onPressed: idle ? () => unawaited(_useLink()) : null,
                  child: _busy == 'link'
                      ? const _InlineProgress()
                      : Text(t.media_banner_link_use),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 默认裁剪：锁 16:9，长边封顶 2560（横幅最多铺满一块 2K 屏，原图更大白占盘）。
/// 裁剪框输出的是无扩展名的 PNG，补上扩展名再交出去（落盘文件名跟源扩展名）。
Future<File?> _cropDefault(BuildContext context, File file) async {
  final File? cropped = await showCropImageDialog(
    context,
    file,
    aspectRatio: kBannerAspect,
    maxDimension: 2560,
  );
  if (cropped == null) return null;
  return cropped.rename('${cropped.path}.png');
}

/// 默认量尺寸：后台 isolate 读文件头（大 EXIF 的 JPEG 会整文件读）。
Future<ImagePixelSize?> _probeSize(File file) async =>
    (await compute(probeIllustrationSizes, <String>[file.path]))[file.path];

/// 当前横幅：小预览 + 「当前横幅」，用户选的另起一行写明重新刮削时保留。
class _CurrentBanner extends StatelessWidget {
  const _CurrentBanner({required this.image, required this.userChosen});

  final ImageProvider image;
  final bool userChosen;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      key: const ValueKey<String>('banner-picker-current'),
      children: <Widget>[
        SizedBox(
          width: 128,
          child: AspectRatio(
            aspectRatio: kBannerAspect,
            child: ClipRRect(
              borderRadius: FushiBorderRadius.chip,
              child: Image(
                image: image,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: FushiIcon(
                    FushiIcons.brokenImage,
                    color: scheme.outline,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.media_banner_current, style: text.titleSmall),
              if (userChosen)
                Text(
                  t.media_banner_current_locked,
                  key: const ValueKey<String>('banner-picker-current-locked'),
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一张候选：16:9 卡片，图铺满、角标压在底部渐变上；悬停抬升、按压回弹
/// （[FushiCard] 自带按压缩放）。
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final BannerCandidate candidate;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? label = candidate.label;
    return FushiHoverLift(
      enabled: enabled,
      builder: (BuildContext context, bool _) => Semantics(
        button: true,
        label: label ?? t.media_banner_title,
        child: FushiCard(
          key: ValueKey<String>('banner-candidate-${candidate.id}'),
          padding: EdgeInsets.zero,
          onTap: enabled ? onTap : null,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image(
                image: candidate.preview,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: FushiIcon(
                    FushiIcons.brokenImage,
                    color: scheme.outline,
                  ),
                ),
              ),
              if (label != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Color(0x00000000), Color(0x99000000)],
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: const Color(0xFFFFFFFF)),
                        ),
                      ),
                    ),
                  ),
                ),
              if (busy)
                const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: _InlineProgress()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineProgress extends StatelessWidget {
  const _InlineProgress();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 20,
    child: FushiCircularProgressIndicator(strokeWidth: 2),
  );
}
