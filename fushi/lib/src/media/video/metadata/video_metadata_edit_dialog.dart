/// 作品资料手填入口（BUG-5082）。
///
/// 三家主源都查不到的作品此前没有作品行，详情页只有标题；这里让用户直接填
/// 标题 / 原名 / 年份 / 简介 / 标语 / 类型 / 制作公司。落库与字段锁语义全在
/// [VideoMetadataDatabaseStore.applyManualEdit]：改过的字段上锁（之后刮削保留），
/// 清空的字段解锁（下次刮削回填）。与「锁定字段」对话框共用同一组字段标签。
library;

import 'package:flutter/services.dart'
    show
        FilteringTextInputFormatter,
        LengthLimitingTextInputFormatter,
        TextInputFormatter;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_lock_dialog.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_manual_edit.dart';

/// 读当前值 → 弹编辑框 → 用户保存后落库。返回是否真的写了。
Future<bool> editVideoWorkManualMetadata({
  required BuildContext context,
  required FushiDatabase database,
  required VideoWorkManualTarget target,
  required String fallbackTitle,
}) async {
  final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(database);
  final VideoWorkManualEdit initial = await store.currentManualEdit(
    target,
    fallbackTitle: fallbackTitle,
  );
  if (!context.mounted) return false;
  final VideoWorkManualEdit? edited = await showAppDialog<VideoWorkManualEdit>(
    context: context,
    builder: (BuildContext context) =>
        VideoWorkManualEditDialog(initial: initial),
  );
  if (edited == null) return false;
  // 以打开时的初值为基准判「改没改」：对话框开着时补刮可能已落库，没碰过的字段
  // 不能被旧初值覆盖（见 [VideoMetadataDatabaseStore.applyManualEdit]）。
  await store.applyManualEdit(
    target,
    edited,
    fallbackTitle: fallbackTitle,
    baseline: initial,
  );
  return true;
}

/// 编辑框本体（公开给 widget 测试）。确认时 pop 出用户填的 [VideoWorkManualEdit]。
class VideoWorkManualEditDialog extends StatefulWidget {
  const VideoWorkManualEditDialog({required this.initial, super.key});

  final VideoWorkManualEdit initial;

  @override
  State<VideoWorkManualEditDialog> createState() =>
      _VideoWorkManualEditDialogState();
}

class _VideoWorkManualEditDialogState extends State<VideoWorkManualEditDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.initial.title,
  );
  late final TextEditingController _originalTitle = TextEditingController(
    text: widget.initial.originalTitle ?? '',
  );
  late final TextEditingController _year = TextEditingController(
    text: widget.initial.year?.toString() ?? '',
  );
  late final TextEditingController _overview = TextEditingController(
    text: widget.initial.overview ?? '',
  );
  late final TextEditingController _tagline = TextEditingController(
    text: widget.initial.tagline ?? '',
  );
  late final TextEditingController _genres = TextEditingController(
    text: widget.initial.genres.join(', '),
  );
  late final TextEditingController _studios = TextEditingController(
    text: widget.initial.studios.join(', '),
  );

  @override
  void dispose() {
    for (final TextEditingController controller in <TextEditingController>[
      _title,
      _originalTitle,
      _year,
      _overview,
      _tagline,
      _genres,
      _studios,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  VideoWorkManualEdit _collect() => VideoWorkManualEdit(
    title: _title.text,
    originalTitle: _originalTitle.text,
    overview: _overview.text,
    tagline: _tagline.text,
    year: int.tryParse(_year.text.trim()),
    genres: splitManualTerms(_genres.text),
    studios: splitManualTerms(_studios.text),
  );

  Widget _field({
    required VideoMetadataLockableField field,
    required TextEditingController controller,
    int? maxLines = 1,
    int? minLines,
    String? helperText,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: FushiTextField(
      key: ValueKey<String>('video-work-edit-${field.name}'),
      controller: controller,
      labelText: videoMetadataLockableFieldLabel(field),
      helperText: helperText,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      clearable: true,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.edit),
      title: Text(t.video_work_edit_metadata),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.video_work_edit_metadata_hint,
                style: context.fushiType.bodyMedium.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              _field(
                field: VideoMetadataLockableField.title,
                controller: _title,
              ),
              _field(
                field: VideoMetadataLockableField.originalTitle,
                controller: _originalTitle,
              ),
              _field(
                field: VideoMetadataLockableField.year,
                controller: _year,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
              ),
              _field(
                field: VideoMetadataLockableField.overview,
                controller: _overview,
                maxLines: 8,
                minLines: 3,
                keyboardType: TextInputType.multiline,
              ),
              _field(
                field: VideoMetadataLockableField.tagline,
                controller: _tagline,
              ),
              _field(
                field: VideoMetadataLockableField.genres,
                controller: _genres,
                helperText: t.video_work_edit_terms_hint,
              ),
              _field(
                field: VideoMetadataLockableField.studios,
                controller: _studios,
                helperText: t.video_work_edit_terms_hint,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.pop(context),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('video-work-edit-save'),
          kind: FushiDialogActionKind.primary,
          label: t.dialog_save,
          onPressed: () => Navigator.pop(context, _collect()),
        ),
      ],
    );
  }
}
