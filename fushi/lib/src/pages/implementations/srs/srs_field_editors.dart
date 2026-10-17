/// 笔记编辑页的按类型字段编辑器（对齐 Anki 桌面版 / AnkiDroid 的笔记编辑器）：
///
/// - 富文本（例句、词条……）：所见即所得，加粗 / 斜体 / 下划线 / 颜色；
/// - 结构化 HTML（Yomitan 释义）：卡片 CSS 渲染预览 + 改源码，原 HTML 不经序列化；
/// - 振假名 `漢字[かな]`：上方注音显示，点词改读音；
/// - 图片：缩略图 + 选择 / 替换 / 粘贴 / 删除，新图进 SRS 媒体库（不再塞 base64）；
/// - 音频 `[sound:]`：播放 + 选择文件 / 录音 / 删除；
/// - 卡型开关字段：开关。
///
/// 每个字段都能切到 HTML 源码（按钮或 Ctrl+Shift+X，同 Anki）。类型判据见
/// [srsFieldKindOf]；技术选型说明见 srs_rich_text_controller.dart 文件头。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart'
    show pickSystemFilePath;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/audio_recorder_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rich_text_controller.dart';
import 'package:fushi/src/srs/srs_field_markup.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/clipboard_image.dart';
import 'package:fushi/utils.dart';

/// 一个字段的当前值。编辑器改值走 [edit]；页面整体换值（重读笔记、连续添加后清空、
/// 冲突裁决）走 [reset]，编辑器据 [generation] 重建内部状态。
class SrsFieldModel extends ChangeNotifier {
  SrsFieldModel(this._value);

  String _value;
  int _generation = 0;

  String get value => _value;

  /// [reset] 的次数。
  int get generation => _generation;

  /// 编辑器改值。
  void edit(String value) {
    if (value == _value) return;
    _value = value;
    notifyListeners();
  }

  /// 外部整体换值（编辑器丢弃自身状态，按新值重新判类型）。
  void reset(String value) {
    _value = value;
    _generation++;
    notifyListeners();
  }
}

/// 选到 / 粘到 / 录到的一份媒体。
typedef SrsPickedMedia = ({String name, Uint8List bytes});

/// 字段编辑器取媒体的入口（测试覆写）。
class SrsFieldMediaSource {
  const SrsFieldMediaSource({
    required this.pickImage,
    required this.pickAudio,
    required this.pasteImage,
    this.recordAudio,
  });

  final Future<SrsPickedMedia?> Function(BuildContext context) pickImage;
  final Future<SrsPickedMedia?> Function(BuildContext context) pickAudio;

  /// 剪贴板里的图片；没有返回 null。
  final Future<SrsPickedMedia?> Function() pasteImage;

  /// 录一段音；null = 不提供录音。
  final Future<SrsPickedMedia?> Function(BuildContext context)? recordAudio;
}

/// 选一个文件当场读进内存（随即存进媒体库，原路径不长期引用）：走统一入口的
/// 「当场消费」选择器，不开 iOS 媒体资料库。
Future<SrsPickedMedia?> _pickFile(
  BuildContext context,
  Set<String> extensions,
) async {
  final String? path = await pickSystemFilePath(
    context: context,
    allowedExtensions: extensions,
  );
  if (path == null) return null;
  return (name: p.basename(path), bytes: await File(path).readAsBytes());
}

const Set<String> _kAudioExtensions = <String>{
  'mp3',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'flac',
  'webm',
};

const Set<String> _kImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'avif',
};

Future<SrsPickedMedia?> _pasteClipboardImage() async {
  final ClipboardImageData? data = await readClipboardImage();
  if (data == null) return null;
  final Uint8List? bytes = data.bytes;
  if (bytes != null) {
    final bool jpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    return (name: jpeg ? 'clipboard.jpg' : 'clipboard.png', bytes: bytes);
  }
  for (final String path in data.paths) {
    if (!_kImageExtensions.contains(SrsMediaStore.extensionOf(path))) continue;
    final File file = File(path);
    if (await file.exists()) {
      return (name: p.basename(path), bytes: await file.readAsBytes());
    }
  }
  return null;
}

Future<SrsPickedMedia?> _recordAudio(BuildContext context) async {
  final Directory tmp = await getTemporaryDirectory();
  final String path = p.join(
    tmp.path,
    'srs_record',
    '${DateTime.now().millisecondsSinceEpoch}',
    'recording.m4a',
  );
  await Directory(p.dirname(path)).create(recursive: true);
  if (!context.mounted) return null;
  File? saved;
  await showAppDialog<void>(
    context: context,
    builder: (_) =>
        AudioRecorderDialogPage(filePath: path, onSave: (File f) => saved = f),
  );
  final File? file = saved;
  if (file == null || !await file.exists()) return null;
  return (name: 'recording.m4a', bytes: await file.readAsBytes());
}

/// 生产实现：系统文件选择器 / app 剪贴板通道 / 现有录音对话框。
final Provider<SrsFieldMediaSource> srsFieldMediaSourceProvider =
    Provider<SrsFieldMediaSource>(
      (Ref ref) => SrsFieldMediaSource(
        pickImage: (BuildContext context) =>
            _pickFile(context, _kImageExtensions),
        pickAudio: (BuildContext context) =>
            _pickFile(context, _kAudioExtensions),
        pasteImage: _pasteClipboardImage,
        recordAudio: _recordAudio,
      ),
    );

/// 字段里图片的来源：媒体库文件名 → 文件；`data:image/<光栅格式>;base64` → 内存
/// （旧笔记里塞的 base64 照常显示）。SVG、远程 URL 与解析失败一律 null（显示占位）。
/// 与复习页原生卡面同一判据。
ImageProvider<Object>? srsFieldImageProvider(String src, SrsMediaStore? store) {
  if (src.startsWith('data:')) {
    if (!src.startsWith('data:image/') || src.startsWith('data:image/svg')) {
      return null;
    }
    try {
      return MemoryImage(UriData.parse(src).contentAsBytes());
    } on FormatException {
      return null;
    }
  }
  if (src.contains('://')) return null;
  final File? file = store?.resolve(src);
  return file == null ? null : FileImage(file);
}

/// 文字颜色色板（ARGB）。
const List<int> kSrsFieldColorPalette = <int>[
  0xFFE53935,
  0xFFFB8C00,
  0xFFF9A825,
  0xFF43A047,
  0xFF00897B,
  0xFF1E88E5,
  0xFF8E24AA,
  0xFF757575,
];

/// 一个字段的编辑器。
class SrsFieldEditor extends ConsumerStatefulWidget {
  const SrsFieldEditor({
    super.key,
    required this.name,
    required this.model,
    this.toggle = false,
    this.css = '',
    this.fushiCard = false,
    this.footer,
  });

  /// 字段名（标题；也参与类型判据）。
  final String name;
  final SrsFieldModel model;

  /// 这是卡型开关字段（非空 = 开）。
  final bool toggle;

  /// 笔记类型的 CSS（结构化预览用）。
  final String css;

  /// 内置「Fushi 卡片」类型（结构化预览吃外观设置）。
  final bool fushiCard;

  /// 字段下方的附加内容（同步冲突候选）。
  final Widget? footer;

  @override
  ConsumerState<SrsFieldEditor> createState() => _SrsFieldEditorState();
}

class _SrsFieldEditorState extends ConsumerState<SrsFieldEditor> {
  late SrsFieldKind _kind;
  late int _generation;
  bool _source = false;
  bool _palette = false;
  bool _busy = false;
  SrsRichTextController? _rich;
  final TextEditingController _sourceCtl = TextEditingController();
  final FocusNode _richFocus = FocusNode(debugLabel: 'srs-field-rich');
  final FocusNode _sourceFocus = FocusNode(debugLabel: 'srs-field-source');
  double _previewHeight = 96;

  SrsFieldModel get _model => widget.model;

  @override
  void initState() {
    super.initState();
    _generation = _model.generation;
    _setup();
    _model.addListener(_onModel);
    _richFocus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(SrsFieldEditor old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
      _generation = widget.model.generation;
      _source = false;
      _setup();
    }
  }

  @override
  void dispose() {
    _model.removeListener(_onModel);
    _rich?.dispose();
    _sourceCtl.dispose();
    _richFocus.dispose();
    _sourceFocus.dispose();
    super.dispose();
  }

  /// 按当前值判类型，重建富文本控制器。
  void _setup() {
    _kind = srsFieldKindOf(widget.name, _model.value, toggle: widget.toggle);
    final SrsRichTextController? old = _rich;
    _rich = _kind == SrsFieldKind.rich
        ? (SrsRichTextController.tryParse(_model.value)?..addListener(_onRich))
        : null;
    if (old != null) {
      old.removeListener(_onRich);
      // 旧控制器还挂在本帧的 TextField 上：等它换下来再释放。
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  void _onRich() => _model.edit(_rich!.html);

  void _onModel() {
    if (!mounted) return;
    if (_model.generation != _generation) {
      setState(() {
        _generation = _model.generation;
        _source = false;
        _palette = false;
        _setup();
      });
      return;
    }
    // 富文本自己的输入已经在 TextField 里画出来了，不用整块重建。
    if (_kind != SrsFieldKind.rich || _source) setState(() {});
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() {
      if (!_richFocus.hasFocus) _palette = false;
    });
  }

  void _toggleSource() {
    setState(() {
      if (_source) {
        _source = false;
        _setup();
        if (_rich != null) _focusLater(_richFocus);
      } else {
        _sourceCtl.text = _model.value;
        _source = true;
        _palette = false;
        _focusLater(_sourceFocus);
      }
    });
  }

  void _focusLater(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  Future<SrsMediaStore> _mediaStore() async {
    final SrsMediaStore? store = await ref.read(srsMediaStoreProvider.future);
    if (store == null) throw StateError('srs media store unavailable');
    return store;
  }

  /// 取一份媒体存进媒体库，交给 [apply] 写回字段。
  Future<void> _addMedia(
    String what,
    Future<SrsPickedMedia?> Function() pick,
    String Function(String value, String name) apply, {
    String? emptyMessage,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final SrsPickedMedia? media = await pick();
      if (media == null) {
        if (emptyMessage != null) FushiToast.show(msg: emptyMessage);
        return;
      }
      final String name = await (await _mediaStore()).store(
        media.name,
        media.bytes,
      );
      _model.edit(apply(_model.value, name));
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsFieldEditor.$what', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playSound(String name) async {
    try {
      final File? file = (await _mediaStore()).resolve(name);
      if (file == null || !await file.exists()) {
        FushiToast.show(
          msg: t.srs_note_audio_missing,
          severity: ToastSeverity.error,
        );
        return;
      }
      await ref.read(srsSoundPlayerProvider)(file.path);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsFieldEditor.play', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  Future<void> _editReading(int index, SrsFuriganaPair pair) async {
    final String? reading = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_furigana_reading(base: pair.base),
      initialValue: pair.reading,
      allowEmpty: true,
    );
    if (reading == null || !mounted) return;
    _model.edit(srsSetFuriganaReading(_model.value, index, reading));
  }

  // ------------------------------------------------------------ build

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final SrsRichTextController? rich = _source ? null : _rich;
    void toggle(SrsRichAttr a) => rich?.toggle(a);
    return <ShortcutActivator, VoidCallback>{
      if (_kind != SrsFieldKind.toggle) ...<ShortcutActivator, VoidCallback>{
        const SingleActivator(
          LogicalKeyboardKey.keyX,
          control: true,
          shift: true,
        ): _toggleSource,
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true, shift: true):
            _toggleSource,
      },
      if (rich != null) ...<ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            toggle(SrsRichAttr.bold),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            toggle(SrsRichAttr.bold),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            toggle(SrsRichAttr.italic),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            toggle(SrsRichAttr.italic),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
            toggle(SrsRichAttr.underline),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () =>
            toggle(SrsRichAttr.underline),
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    final Widget body = _source ? _buildSource(context) : _buildBody(context);
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          _buildHeader(context),
          FushiAnimatedSize(
            duration: motion,
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: motion,
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.topCenter,
                children: <Widget>[...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey<String>('${_kind.name}-$_source-$_generation'),
                child: body,
              ),
            ),
          ),
          ?widget.footer,
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget label = Text(
      widget.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.fushiType.labelLarge.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (_kind == SrsFieldKind.toggle) {
      return Row(
        children: <Widget>[
          Expanded(child: label),
          FushiSwitch(
            key: ValueKey<String>('srs-field-toggle-${widget.name}'),
            value: _model.value.trim().isNotEmpty,
            onChanged: (bool on) => _model.edit(on ? 'x' : ''),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: label),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox.square(
              dimension: 16,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        FushiIconButton(
          key: ValueKey<String>('srs-field-source-${widget.name}'),
          icon: FushiIcons.code,
          size: 20,
          selected: _source,
          tooltip: _source
              ? t.srs_note_field_source_hide
              : t.srs_note_field_source_show,
          onTap: _toggleSource,
        ),
      ],
    );
  }

  Widget _buildSource(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget field = FushiTextField(
      key: ValueKey<String>('srs-field-source-input-${widget.name}'),
      controller: _sourceCtl,
      focusNode: _sourceFocus,
      minLines: 2,
      maxLines: 12,
      keyboardType: TextInputType.multiline,
      style: context.fushiType.bodyMedium.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['Consolas', 'Menlo', 'monospace'],
      ),
      onChanged: _model.edit,
    );
    if (_kind != SrsFieldKind.furigana) return field;
    // 振假名的「源码」就是 Anki 写法：边改边在上面看注音。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        if (_model.value.trim().isNotEmpty) _furiganaText(context, tap: false),
        field,
      ],
    );
  }

  Widget _buildBody(BuildContext context) => switch (_kind) {
    SrsFieldKind.rich => _buildRich(context),
    SrsFieldKind.structured => _buildStructured(context),
    SrsFieldKind.furigana => _buildFurigana(context),
    SrsFieldKind.image => _buildImages(context),
    SrsFieldKind.audio => _buildAudio(context),
    SrsFieldKind.toggle => const SizedBox.shrink(),
  };

  // ------------------------------------------------------------ 富文本

  Widget _buildRich(BuildContext context) {
    final SrsRichTextController? rich = _rich;
    if (rich == null) return _buildStructured(context);
    final bool showToolbar = _richFocus.hasFocus || _palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiTextField(
          key: ValueKey<String>('srs-field-input-${widget.name}'),
          controller: rich,
          focusNode: _richFocus,
          minLines: 1,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topLeft,
          child: showToolbar
              ? TextFieldTapRegion(child: _toolbar(context, rich))
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context, SrsRichTextController rich) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListenableBuilder(
      listenable: rich,
      builder: (BuildContext context, _) {
        final TextStyle base = context.fushiType.titleMedium;
        final int? color = rich.activeColor;
        return Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: tokens.spacing.gap / 2,
            children: <Widget>[
              Wrap(
                spacing: tokens.spacing.gap / 2,
                runSpacing: tokens.spacing.gap / 2,
                children: <Widget>[
                  _SrsFormatToggle(
                    key: ValueKey<String>('srs-format-bold-${widget.name}'),
                    tooltip: t.srs_note_format_bold,
                    selected: rich.isActive(SrsRichAttr.bold),
                    onTap: () => rich.toggle(SrsRichAttr.bold),
                    child: const FushiIcon(FushiIcons.bold, size: 20),
                  ),
                  _SrsFormatToggle(
                    key: ValueKey<String>('srs-format-italic-${widget.name}'),
                    tooltip: t.srs_note_format_italic,
                    selected: rich.isActive(SrsRichAttr.italic),
                    onTap: () => rich.toggle(SrsRichAttr.italic),
                    child: Text(
                      'I',
                      style: base.copyWith(fontStyle: FontStyle.italic),
                    ),
                  ),
                  _SrsFormatToggle(
                    key: ValueKey<String>(
                      'srs-format-underline-${widget.name}',
                    ),
                    tooltip: t.srs_note_format_underline,
                    selected: rich.isActive(SrsRichAttr.underline),
                    onTap: () => rich.toggle(SrsRichAttr.underline),
                    child: Text(
                      'U',
                      style: base.copyWith(
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  _SrsFormatToggle(
                    key: ValueKey<String>('srs-format-color-${widget.name}'),
                    tooltip: t.srs_note_format_color,
                    selected: _palette,
                    onTap: () => setState(() => _palette = !_palette),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('A', style: base.copyWith(height: 1)),
                        Container(
                          width: 16,
                          height: 3,
                          margin: const EdgeInsets.only(top: 2),
                          decoration: BoxDecoration(
                            borderRadius: tokens.radii.chipRadius,
                            color: color == null
                                ? Theme.of(context).colorScheme.onSurface
                                : Color(color),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              FushiAnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                alignment: Alignment.topLeft,
                child: _palette
                    ? _paletteRow(context, rich, color)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _paletteRow(
    BuildContext context,
    SrsRichTextController rich,
    int? current,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    Widget swatch(int? argb, String tooltip) {
      final bool selected = current == argb;
      return FushiTooltip(
        message: tooltip,
        child: FushiPressScale(
          child: GestureDetector(
            key: ValueKey<String>(
              'srs-format-swatch-${argb == null ? 'none' : srsCssColor(argb)}',
            ),
            onTap: () => rich.setColor(argb),
            child: AnimatedContainer(
              duration: fushiMotionDuration(context, FushiMotion.short),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: argb == null
                    ? FushiDesignTokens.of(context).surfaces.page
                    : Color(argb),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              child: argb == null
                  ? FushiIcon(
                      FushiIcons.block,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        swatch(null, t.srs_note_format_color_default),
        for (final int c in kSrsFieldColorPalette) swatch(c, srsCssColor(c)),
      ],
    );
  }

  // ------------------------------------------------------------ 结构化

  Widget _buildStructured(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SrsCardFaceBuilder builder = ref.watch(srsCardFaceBuilderProvider);
    final String language = ref.read(appProvider).defaultContentLanguage;
    final double height = _previewHeight.clamp(56.0, 360.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        AnimatedContainer(
          key: ValueKey<String>('srs-field-preview-${widget.name}'),
          duration: fushiMotionDuration(context, FushiMotion.short),
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: tokens.radii.controlRadius,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: builder(
            context,
            SrsCardFace(
              cardId: 'note-editor#${widget.name}',
              showingAnswer: true,
              bodyHtml: _model.value,
              css: widget.css,
              languageCode: language.isEmpty ? null : language,
              onBridgeKey: (_) {},
              bridgeKeys: const <String>[],
              layout: SrsCardLayout.narrow,
              fushiCard: widget.fushiCard,
              onContentHeight: (double h) {
                if (mounted && (h - _previewHeight).abs() >= 1) {
                  setState(() => _previewHeight = h);
                }
              },
            ),
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.srs_note_field_structured_hint,
                style: context.fushiType.bodySmall.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            FushiTextButton.icon(
              onPressed: _toggleSource,
              icon: const FushiIcon(FushiIcons.code, size: 18),
              label: Text(t.srs_note_field_source_show),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 振假名

  Widget _furiganaText(BuildContext context, {required bool tap}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String value = _model.value;
    final List<SrsInline> segments = srsParseInline(value);
    final List<SrsFuriganaPair> pairs = srsFuriganaPairs(value);
    final List<SrsInline> rubies = segments
        .where((SrsInline s) => s.ruby != null)
        .toList();
    // 显示里的第 k 个注音段 ↔ 原文第 k 组 `基字[读音]`：对不上（混了 <ruby> 标签等）
    // 就不按词改，点了进源码。
    bool mappable = rubies.length == pairs.length;
    for (int i = 0; mappable && i < pairs.length; i++) {
      if (srsDecodeEntities(pairs[i].base) != rubies[i].text) mappable = false;
    }
    final TextStyle style = context.fushiType.titleLarge.copyWith(height: 1.4);
    final TextStyle rubyStyle = context.fushiType.labelSmall.copyWith(
      color: scheme.primary,
      height: 1.1,
    );
    TextStyle styleOf(SrsInline s) => style.copyWith(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: s.underline ? TextDecoration.underline : null,
    );
    int k = 0;
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final SrsInline s in segments) {
      if (s.ruby == null) {
        spans.add(TextSpan(text: s.text, style: styleOf(s)));
        continue;
      }
      final int index = k++;
      final Widget ruby = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(s.ruby!, style: rubyStyle, maxLines: 1),
          Text(s.text, style: styleOf(s), maxLines: 1),
        ],
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.bottom,
          child: !tap
              ? ruby
              : FushiPressScale(
                  child: InkWell(
                    key: ValueKey<String>('srs-furigana-${widget.name}-$index'),
                    borderRadius: FushiDesignTokens.of(
                      context,
                    ).radii.chipRadius,
                    onTap: mappable
                        ? () => unawaited(_editReading(index, pairs[index]))
                        : _toggleSource,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: ruby,
                    ),
                  ),
                ),
        ),
      );
    }
    return Text.rich(TextSpan(children: spans), style: style);
  }

  Widget _buildFurigana(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_model.value.trim().isEmpty) return _buildSource(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        Container(
          padding: EdgeInsets.all(tokens.spacing.gap),
          decoration: BoxDecoration(
            color: tokens.surfaces.card,
            borderRadius: tokens.radii.controlRadius,
          ),
          child: _furiganaText(context, tap: true),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.srs_note_furigana_hint,
                style: context.fushiType.bodySmall.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            FushiTextButton.icon(
              key: ValueKey<String>('srs-furigana-edit-${widget.name}'),
              onPressed: _toggleSource,
              icon: const FushiIcon(FushiIcons.edit, size: 18),
              label: Text(t.srs_note_furigana_edit_text),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 图片

  Widget _buildImages(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldMediaSource source = ref.watch(srsFieldMediaSourceProvider);
    final SrsMediaStore? store = ref.watch(srsMediaStoreProvider).valueOrNull;
    final List<String> images = srsImageSources(_model.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        if (images.isNotEmpty)
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (int i = 0; i < images.length; i++)
                _SrsImageTile(
                  key: ValueKey<String>('srs-image-${widget.name}-$i'),
                  provider: srsFieldImageProvider(images[i], store),
                  onReplace: () => _addMedia(
                    'replaceImage',
                    () => source.pickImage(context),
                    (String v, String name) => srsReplaceImage(v, i, name),
                  ),
                  onRemove: () =>
                      _model.edit(srsReplaceImage(_model.value, i, null)),
                ),
            ],
          ),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiOutlinedButton.icon(
              key: ValueKey<String>('srs-image-pick-${widget.name}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _addMedia(
                        'pickImage',
                        () => source.pickImage(context),
                        srsAppendImage,
                      ),
                    ),
              icon: const FushiIcon(FushiIcons.image, size: 18),
              label: Text(t.srs_note_image_pick),
            ),
            FushiOutlinedButton.icon(
              key: ValueKey<String>('srs-image-paste-${widget.name}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _addMedia(
                        'pasteImage',
                        source.pasteImage,
                        srsAppendImage,
                        emptyMessage: t.srs_note_image_paste_empty,
                      ),
                    ),
              icon: const FushiIcon(FushiIcons.paste, size: 18),
              label: Text(t.srs_note_image_paste),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 音频

  Widget _buildAudio(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SrsFieldMediaSource source = ref.watch(srsFieldMediaSourceProvider);
    final List<String> sounds = srsSoundNames(_model.value);
    final Future<SrsPickedMedia?> Function(BuildContext)? record =
        source.recordAudio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (int i = 0; i < sounds.length; i++)
          Container(
            key: ValueKey<String>('srs-sound-${widget.name}-$i'),
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap / 2),
            decoration: BoxDecoration(
              color: tokens.surfaces.card,
              borderRadius: tokens.radii.controlRadius,
            ),
            child: Row(
              children: <Widget>[
                FushiIconButton(
                  key: ValueKey<String>('srs-sound-play-${widget.name}-$i'),
                  icon: FushiIcons.playCircle,
                  tooltip: t.play,
                  enabledColor: scheme.primary,
                  onTap: () => _playSound(sounds[i]),
                ),
                Expanded(
                  child: Text(
                    sounds[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodyMedium,
                  ),
                ),
                FushiIconButton(
                  icon: FushiIcons.delete,
                  tooltip: t.srs_note_audio_remove,
                  onTap: () =>
                      _model.edit(srsReplaceSound(_model.value, i, null)),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiOutlinedButton.icon(
              key: ValueKey<String>('srs-sound-pick-${widget.name}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _addMedia(
                        'pickAudio',
                        () => source.pickAudio(context),
                        srsAppendSound,
                      ),
                    ),
              icon: const FushiIcon(FushiIcons.audio, size: 18),
              label: Text(t.srs_note_audio_pick),
            ),
            if (record != null)
              FushiOutlinedButton.icon(
                key: ValueKey<String>('srs-sound-record-${widget.name}'),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _addMedia(
                          'recordAudio',
                          () => record(context),
                          srsAppendSound,
                        ),
                      ),
                icon: const FushiIcon(FushiIcons.mic, size: 18),
                label: Text(t.srs_note_audio_record),
              ),
          ],
        ),
      ],
    );
  }
}

/// 格式按钮（开关态）：选中时 secondaryContainer 底，按压缩放。
class _SrsFormatToggle extends StatelessWidget {
  const _SrsFormatToggle({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color fg = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: selected,
        label: tooltip,
        child: FushiPressScale(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              canRequestFocus: false,
              borderRadius: tokens.radii.controlRadius,
              child: AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                width: 44,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.secondaryContainer
                      : tokens.surfaces.search,
                  borderRadius: tokens.radii.controlRadius,
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: fg),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: fg),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一张图片的缩略图 + 替换 / 删除。
class _SrsImageTile extends StatelessWidget {
  const _SrsImageTile({
    super.key,
    required this.provider,
    required this.onReplace,
    required this.onRemove,
  });

  final ImageProvider<Object>? provider;
  final Future<void> Function() onReplace;
  final VoidCallback onRemove;

  static const double _size = 120;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider<Object>? image = provider;
    final Widget broken = ColoredBox(
      color: tokens.surfaces.overlay,
      child: Center(
        child: FushiIcon(
          FushiIcons.brokenImage,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    return SizedBox(
      width: _size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiPressScale(
            child: GestureDetector(
              onTap: image == null
                  ? null
                  : () => unawaited(
                      showAppDialog<void>(
                        context: context,
                        builder: (BuildContext context) => GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: InteractiveViewer(child: Image(image: image)),
                        ),
                      ),
                    ),
              child: ClipRRect(
                borderRadius: tokens.radii.controlRadius,
                child: SizedBox.square(
                  dimension: _size,
                  child: image == null
                      ? broken
                      : Image(
                          image: image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => broken,
                        ),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              FushiIconButton(
                icon: FushiIcons.swap,
                size: 20,
                tooltip: t.srs_note_image_replace,
                onTap: onReplace,
              ),
              FushiIconButton(
                icon: FushiIcons.delete,
                size: 20,
                tooltip: t.srs_note_image_remove,
                onTap: onRemove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
