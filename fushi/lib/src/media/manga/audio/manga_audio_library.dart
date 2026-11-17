/// 漫画有声成品入库：把 [MangaRenderManifest] 写成这卷的 `Audiobooks` 行 + `AudioCues`
/// （形态见 `manga_audio_render.dart` 的库注释），播放走 `AudiobookSession`。
///
/// 生成端（`manga_audio_render_service.dart`）整卷生成、补回、保留单句候选后都调
/// [registerMangaAudio]；每次按清单整份重写，cue 与清单行一一对应。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:path/path.dart' as p;

/// 清单 → `Audiobooks` / `AudioCues`。`audioPathsJson` 存绝对路径（按清单行顺序，
/// `AudiobookRepository.replaceAudio` 的契约）；每行一条 cue：`chapterHref` = 页、
/// `textFragmentId` = 块下标、`startMs = 0`、`endMs = 时长`、`audioFileIndex` 与
/// `sentenceIndex` = 行下标。占位静音行同样有 cue（高亮照常走到它）。
Future<void> registerMangaAudio(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
  required MangaRenderManifest manifest,
}) async {
  final String dir = manifestFile.parent.path;
  final AudiobookRepository repo = AudiobookRepository(db);
  await repo.ensureAudiobook(bookKey);
  await repo.replaceAlignment(
    bookKey: bookKey,
    format: kMangaAlignmentFormat,
    path: manifestFile.path,
  );
  await repo.replaceAudio(
    bookKey: bookKey,
    audioPaths: <String>[
      for (final String f in manifest.audioFiles) p.join(dir, f),
    ],
  );
  await repo.saveCues(
    bookKey: bookKey,
    cues: <AudioCue>[
      for (int i = 0; i < manifest.lines.length; i++)
        AudioCue()
          ..bookKey = bookKey
          ..chapterHref = mangaPageHref(manifest.lines[i].page)
          ..sentenceIndex = i
          ..textFragmentId = mangaBlocksFragment(manifest.lines[i].blocks)
          ..text = manifest.lines[i].text
          ..startMs = 0
          ..endMs = manifest.lines[i].durationMs
          ..audioFileIndex = i,
    ],
  );
}
