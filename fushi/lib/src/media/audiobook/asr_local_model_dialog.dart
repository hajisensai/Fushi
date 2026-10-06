/// 「手动指定模型」弹层：选一个本地文件夹 → 认出里面的 sherpa-onnx 导出 → 填名字
/// 和几个解码契约参数 → 返回一个可直接跑的 [AsrModelPack]。
///
/// 落盘与注册由调用方做（`saveAsrModelCatalog`），本弹层是纯的「拿到一个包」。
///
/// **为什么要让用户填 blank 记号 / 上下文长度 / 索引整型**：这三样是模型文件里读
/// 不出来的解码契约（见 `asr_model_manifest.dart` 文件头的逐模型核实表）。写错的
/// 后果分两种，都得让用户能自己改：索引整型与上下文长度错 → ORT 建会话当场报
/// 形状不符，跑不起来；blank 记号错 → **不报错**，整篇转录变成乱码。默认值取
/// sherpa-onnx 导出的常见形态（`<blk>` / 2 / int64），照着导出的人不用动。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开「手动指定模型」弹层。返回认好的包；取消返回 null。
///
/// [language]：这个模型服务哪种语言——就是用户当前在转录弹层里选的那一种。不再
/// 多一个语言选择器：在日语下点「手动指定模型」，接进来的当然是给日语用的。
///
/// [directoryPicker] 测试注入；null = 真的系统目录选择器。
Future<AsrModelPack?> showAsrLocalModelDialog({
  required BuildContext context,
  required AsrLanguage language,
  Future<String?> Function()? directoryPicker,
}) {
  Widget build(BuildContext ctx) => AsrLocalModelDialog(
        language: language,
        directoryPicker: directoryPicker,
      );
  if (isDesktopPlatform) {
    return showAppDialog<AsrModelPack>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 520,
        maxHeightFactor: 0.8,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<AsrModelPack>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

/// 纯函数：把扫描失败的原因翻成给用户看的一句话。
String asrLocalModelProblemMessage(AsrLocalModelProblem problem) =>
    switch (problem) {
      AsrLocalModelProblem.missingTokens =>
        t.audiobook_transcribe_model_custom_error_tokens,
      AsrLocalModelProblem.missingModel =>
        t.audiobook_transcribe_model_custom_error_model,
      AsrLocalModelProblem.incompleteTransducer =>
        t.audiobook_transcribe_model_custom_error_transducer,
    };

@visibleForTesting
class AsrLocalModelDialog extends StatefulWidget {
  const AsrLocalModelDialog({
    required this.language,
    this.directoryPicker,
    super.key,
  });

  final AsrLanguage language;
  final Future<String?> Function()? directoryPicker;

  @override
  State<AsrLocalModelDialog> createState() => _AsrLocalModelDialogState();
}

class _AsrLocalModelDialogState extends State<AsrLocalModelDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _blank = TextEditingController(text: '<blk>');
  String? _dirPath;
  int _contextSize = 2;
  AsrIndexType _indexType = AsrIndexType.int64;
  bool _advanced = false;

  /// 上一次扫描的结果：认出来的包（此时表单里的改动会重新套上去）或一条问题。
  AsrModelPack? _scanned;
  AsrLocalModelProblem? _problem;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _blank.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final Future<String?> Function()? picker = widget.directoryPicker;
    final String? dir = picker == null
        ? await pickRealDirectoryPath(
            context: context,
            appModel: ProviderScope.containerOf(context, listen: false)
                .read(appProvider),
            dialogTitle: t.audiobook_transcribe_model_custom_pick,
          )
        : await picker();
    if (dir == null || dir.trim().isEmpty || !mounted) return;
    setState(() {
      _dirPath = dir;
      if (_name.text.trim().isEmpty) _name.text = p.basename(dir);
    });
    _rescan();
  }

  /// 按当前目录 + 表单值重新认一遍。表单每改一次都重认：包是不可变值，改字段就是
  /// 换一个包，没必要为「先扫描后修补」再造一套可变中间态。
  void _rescan() {
    final String? dir = _dirPath;
    if (dir == null) return;
    setState(() {
      _error = null;
      _problem = null;
      _scanned = null;
    });
    try {
      final AsrLocalModelScan scan = scanLocalAsrModelDirectory(
        dir: Directory(dir),
        displayName: _name.text.trim(),
        languages: <AsrLanguage>[widget.language],
        decoderContextSize: _contextSize,
        indexType: _indexType,
        blankToken: _blank.text.trim().isEmpty ? '<blk>' : _blank.text.trim(),
      );
      setState(() {
        switch (scan) {
          case AsrLocalModelFound(pack: final AsrModelPack pack):
            _scanned = pack;
          case AsrLocalModelRejected(problem: final AsrLocalModelProblem why):
            _problem = why;
        }
      });
    } catch (error) {
      // 目录读不了（权限 / 已拔掉的盘）也要说清楚，不能只显示「没认出模型」。
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final AsrModelPack? pack = _scanned;
    return FushiModalSheetFrame(
      title: t.audiobook_transcribe_model_custom_title,
      leadingIcon: FushiIcons.folderOpen,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.audiobook_transcribe_model_custom_intro,
            style: tokens.type.metadata,
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          _folderCard(context),
          SizedBox(height: tokens.spacing.rowVertical),
          FushiTextField(
            controller: _name,
            labelText: t.audiobook_transcribe_model_custom_name,
            // 名字只影响 displayName 与 id，不影响认哪些文件——不重扫目录
            // （扫描是 listSync + 逐文件 lengthSync，模型目录在网络盘上会逐字卡）。
            onChanged: (String _) => setState(() {}),
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          FushiCard(
            padding: EdgeInsets.zero,
            child: FushiListItem(
              leading: const FushiListLeadingIcon(
                FushiIcons.settings,
                size: 36,
                iconSize: 20,
              ),
              title: Text(t.audiobook_transcribe_model_custom_advanced),
              trailing: AnimatedRotation(
                turns: _advanced ? 0.5 : 0,
                duration: motion.spatialFast.duration,
                curve: motion.spatialFast.curve,
                child: const FushiIcon(FushiIcons.expandMore),
              ),
              onTap: () => setState(() => _advanced = !_advanced),
            ),
          ),
          AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: _advanced
                ? _advancedFields(context, tokens)
                : const SizedBox(width: double.infinity),
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          _statusCard(context, pack),
        ],
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FushiFilledButton.icon(
            key: const ValueKey<String>('asr-local-model-confirm'),
            icon: const FushiIcon(FushiIcons.check, size: 18),
            label: Text(t.dialog_done),
            onPressed: pack == null
                ? null
                : () => Navigator.pop(context, _named(pack)),
          ),
        ],
      ),
    );
  }

  /// 选文件夹卡：形状图标 + 已选路径（未选时是引导文案）+ 选择按钮。整张卡
  /// 也可点，触屏上点哪都能开目录选择器。
  Widget _folderCard(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? dir = _dirPath;
    return FushiCard(
      variant: FushiCardVariant.outlined,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      onTap: _pick,
      child: Row(
        children: <Widget>[
          FushiListLeadingIcon(
            dir == null ? FushiIcons.folder : FushiIcons.folderOpen,
            shape: FushiLeadingShape.square,
            tone: dir == null ? FushiCardTone.secondary : FushiCardTone.primary,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              dir ?? t.audiobook_transcribe_model_custom_pick,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: dir == null
                  ? type.titleSmallEmphasized
                  : type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('asr-local-model-pick'),
            icon: const FushiIcon(FushiIcons.folderOpen, size: 18),
            label: Text(t.audiobook_transcribe_model_custom_pick),
            onPressed: _pick,
          ),
        ],
      ),
    );
  }

  Widget _advancedFields(BuildContext context, FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.rowVertical),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiTextField(
            controller: _blank,
            labelText: t.audiobook_transcribe_model_custom_blank,
            onChanged: (String _) => _rescan(),
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.audiobook_transcribe_model_custom_blank_hint,
            style: tokens.type.metadata,
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_model_custom_context,
            style: context.fushiType.titleSmallEmphasized,
          ),
          SizedBox(height: tokens.spacing.gap),
          FushiSegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 1, label: Text('1')),
              ButtonSegment<int>(value: 2, label: Text('2')),
            ],
            selected: <int>{_contextSize},
            showSelectedIcon: false,
            // 自己 setState：_rescan() 在还没选目录时会提前 return，光靠它
            // 重绘的话，「先展开高级改参数、再选文件夹」这个很自然的顺序下
            // 分段按钮看上去点不动。
            onSelectionChanged: (Set<int> s) {
              setState(() => _contextSize = s.first);
              _rescan();
            },
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_model_custom_index,
            style: context.fushiType.titleSmallEmphasized,
          ),
          SizedBox(height: tokens.spacing.gap),
          FushiSegmentedButton<AsrIndexType>(
            segments: const <ButtonSegment<AsrIndexType>>[
              ButtonSegment<AsrIndexType>(
                value: AsrIndexType.int64,
                label: Text('int64'),
              ),
              ButtonSegment<AsrIndexType>(
                value: AsrIndexType.int32,
                label: Text('int32'),
              ),
            ],
            selected: <AsrIndexType>{_indexType},
            showSelectedIcon: false,
            onSelectionChanged: (Set<AsrIndexType> s) {
              setState(() => _indexType = s.first);
              _rescan();
            },
          ),
        ],
      ),
    );
  }

  /// 扫描结果卡（M3E tonal 色块）：认出 = tertiary、缺文件 / 读不了 = error、
  /// 还没选 = 中性。
  Widget _statusCard(BuildContext context, AsrModelPack? pack) {
    final bool failed = _error != null || _problem != null;
    final FushiCardTone tone = failed
        ? FushiCardTone.error
        : pack != null
            ? FushiCardTone.tertiary
            : FushiCardTone.neutral;
    final IconData icon = failed
        ? FushiIcons.error
        : pack != null
            ? FushiIcons.success
            : FushiIcons.info;
    return AnimatedSwitcher(
      duration: context.fushiMotion.effectsDefault.duration,
      child: FushiCard(
        key: ValueKey<FushiCardTone>(tone),
        tone: tone,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiIcon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                key: const ValueKey<String>('asr-local-model-status'),
                _statusLine(pack),
                style: context.fushiType.bodyMedium.tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 把当前输入框里的名字套进包（改名不重扫目录，所以在确认这一刻套一次）。
  AsrModelPack _named(AsrModelPack pack) {
    final String name = _name.text.trim();
    if (name.isEmpty || name == pack.displayName) return pack;
    final AsrLocalModelScan scan = scanLocalAsrModelDirectory(
      dir: Directory(_dirPath!),
      displayName: name,
      languages: <AsrLanguage>[widget.language],
      decoderContextSize: _contextSize,
      indexType: _indexType,
      blankToken: _blank.text.trim().isEmpty ? '<blk>' : _blank.text.trim(),
    );
    return scan is AsrLocalModelFound ? scan.pack : pack;
  }

  /// 状态行：认出来了报架构与文件数，没认出来报具体缺什么。
  String _statusLine(AsrModelPack? pack) {
    final String? error = _error;
    if (error != null) return error;
    final AsrLocalModelProblem? problem = _problem;
    if (problem != null) return asrLocalModelProblemMessage(problem);
    if (pack == null) return t.audiobook_transcribe_model_custom_intro;
    final String kind =
        pack.architecture == AsrModelArchitecture.ctc ? 'CTC' : 'transducer';
    return '$kind · ${pack.files.length} · '
        '${FushiByteFormat.bytes(pack.totalBytes(AsrEncoderVariant.int8))}';
  }
}
