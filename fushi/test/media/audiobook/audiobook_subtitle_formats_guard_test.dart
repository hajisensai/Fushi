// 有声书字幕格式只有一份真相源（kAudiobookSubtitleExtensions）：各入口引用它而不是
// 各写一份。此前同一组 srt/lrc/vtt/ass/ssa 手抄了七处，加一种格式就得记得改七处。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/import/sidecar_finder.dart';
import 'package:fushi/src/ops/ctl_audiobook_routes.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/subtitle_rematch_policy.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';

/// 手抄的有声书字幕集合：一个 Set 字面量里同时出现 'srt' 与 'lrc'。
final RegExp _handCopiedSet = RegExp(
  r"<String>\s*\{[^{}]*'\.?srt'[^{}]*'\.?lrc'[^{}]*\}|<String>\s*\{[^{}]*'\.?lrc'[^{}]*'\.?srt'[^{}]*\}",
);

void main() {
  test('派生集合与真相源一致', () {
    expect(kDragSubtitleExtensions, same(kAudiobookSubtitleExtensions));
    expect(defaultSubtitleExts, same(kAudiobookSubtitleExtensions));
    expect(
      SubtitleRematchPolicy.supportedFormats,
      same(kAudiobookSubtitleExtensions),
    );
    expect(kDiscoverySubtitleExtensions, <String>{
      for (final String ext in kAudiobookSubtitleExtensions) '.$ext',
    });
    expect(
      kAudiobookCtlSubtitleExtensions.containsAll(kAudiobookSubtitleExtensions),
      isTrue,
    );
    for (final String ext in kAudiobookSubtitleExtensions) {
      final AudiobookshelfLibraryFile file = AudiobookshelfLibraryFile.parse(
        <String, Object?>{
          'ino': '1',
          'metadata': <String, Object?>{
            'filename': 'Book.${ext.toUpperCase()}',
          },
        },
      )!;
      expect(file.isSubtitle, isTrue, reason: ext);
      expect(isAudiobookSubtitleExtension('.$ext'), isTrue);
    }
  });

  test('app 与引擎源码里没有手抄的有声书字幕集合', () {
    const String truth = 'media/audiobook/audiobook_subtitle_formats.dart';
    final List<String> offenders = <String>[];
    for (final String root in <String>['lib', '../packages/fushi_engine/lib']) {
      for (final FileSystemEntity entity in Directory(
        root,
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll('\\', '/');
        if (path.endsWith(truth) || path.endsWith('.g.dart')) continue;
        if (_handCopiedSet.hasMatch(entity.readAsStringSync())) {
          offenders.add(path);
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
