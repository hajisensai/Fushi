/// 作品级字段锁的编辑入口（schema v99）。
///
/// 挂在作品详情页的管理菜单上：勾上的字段在下一次刮削时保留当前值。写库走
/// [FushiDatabase.setVideoMetadataWorkLockedFields]——锁是纯用户意图，和刮削
/// 产物同表不同源，不经 `upsertVideoMetadataWork`。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 每个可锁字段在 UI 上的标签。genres / studios 复用作品详情页已有的词条标题。
String videoMetadataLockableFieldLabel(VideoMetadataLockableField field) =>
    switch (field) {
      VideoMetadataLockableField.title => t.video_work_field_title,
      VideoMetadataLockableField.originalTitle =>
        t.video_work_field_original_title,
      VideoMetadataLockableField.overview => t.video_work_field_overview,
      VideoMetadataLockableField.tagline => t.video_work_field_tagline,
      VideoMetadataLockableField.genres => t.video_work_genres,
      VideoMetadataLockableField.studios => t.video_work_studios,
      VideoMetadataLockableField.rating => t.video_work_field_rating,
      VideoMetadataLockableField.cover => t.video_work_field_cover,
      VideoMetadataLockableField.backdrop => t.video_work_field_backdrop,
      VideoMetadataLockableField.episodeGroup =>
        t.video_work_field_episode_group,
    };

/// 打开字段锁对话框并在用户确认后写库。返回是否真的写了。
Future<bool> editVideoMetadataLockedFields({
  required BuildContext context,
  required FushiDatabase database,
  required int workId,
}) async {
  final VideoMetadataWorkRow? row =
      await database.getVideoMetadataWorkById(workId);
  if (row == null || !context.mounted) return false;
  final Set<VideoMetadataLockableField>? picked =
      await showAppDialog<Set<VideoMetadataLockableField>>(
    context: context,
    builder: (BuildContext context) => _VideoMetadataLockDialog(
      initial: parseLockedFields(row.lockedFields),
    ),
  );
  if (picked == null) return false;
  await database.setVideoMetadataWorkLockedFields(
    workId,
    encodeLockedFields(picked),
  );
  return true;
}

class _VideoMetadataLockDialog extends StatefulWidget {
  const _VideoMetadataLockDialog({required this.initial});

  final Set<VideoMetadataLockableField> initial;

  @override
  State<_VideoMetadataLockDialog> createState() =>
      _VideoMetadataLockDialogState();
}

class _VideoMetadataLockDialogState extends State<_VideoMetadataLockDialog> {
  late final Set<VideoMetadataLockableField> _selected =
      <VideoMetadataLockableField>{...widget.initial};

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.lock),
      title: Text(t.video_work_locked_fields),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.video_work_locked_fields_hint,
                style: context.fushiType.bodyMedium.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              // 分段卡片组（M3E：首尾大圆角、行间 2px；Apple：inset grouped）。
              AdaptiveSettingsSection(
                children: <Widget>[
                  for (final VideoMetadataLockableField field
                      in VideoMetadataLockableField.values)
                    AdaptiveSettingsSwitchRow(
                      key: ValueKey<String>('video-work-lock-${field.name}'),
                      title: videoMetadataLockableFieldLabel(field),
                      value: _selected.contains(field),
                      onChanged: (bool value) => setState(() {
                        if (value) {
                          _selected.add(field);
                        } else {
                          _selected.remove(field);
                        }
                      }),
                    ),
                ],
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
          kind: FushiDialogActionKind.primary,
          label: t.dialog_save,
          onPressed: () => Navigator.pop(context, _selected),
        ),
      ],
    );
  }
}
