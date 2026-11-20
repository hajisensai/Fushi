/// 漫画有声的落盘位置（唯一一处定义；标注、有声书音源、生成、制作台都从这里取）。
///
/// - 演出稿、标注失败账本与小说选角表同目录（`<db>/tts_cast/`），后缀不同互不覆盖；
///   未配音账本与小说共用 `ttsVoicingStoreFor`（同目录同格式）；
/// - 成品在 `<db>/manga_audio/<sha1(bookKey)>/`（清单 + 每句一个文件）；
/// - 广播剧 / 动画音轨的成品在 `<db>/manga_drama/<sha1(bookKey)>/`（清单 + 每段一个
///   文件），与合成成品分开放：两者都能登记成这卷的有声成品，换来换去不互相清文件。
library;

import 'dart:io';

import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';

Directory _castDir(AudioProductionHost appModel) =>
    Directory(p.join(appModel.databaseDirectory.path, 'tts_cast'));

/// 每卷演出稿：`<db>/tts_cast/<sha1>.manga-script.json`。
MangaAudioScriptStore mangaAudioScriptStoreFor(AudioProductionHost appModel) =>
    MangaAudioScriptStore(_castDir(appModel));

/// 标注失败账本：`<db>/tts_cast/<sha1>.manga-annotate.json`。
MangaAnnotationLedgerStore mangaAnnotationLedgerStoreFor(
  AudioProductionHost appModel,
) => MangaAnnotationLedgerStore(_castDir(appModel));

/// 成品根目录。
Directory mangaAudioRoot(AudioProductionHost appModel) =>
    Directory(p.join(appModel.databaseDirectory.path, 'manga_audio'));

/// 一卷的成品清单文件。
File mangaRenderManifestFile(AudioProductionHost appModel, String bookKey) =>
    MangaRenderManifest.fileFor(mangaAudioRoot(appModel), bookKey);

/// 广播剧 / 动画音轨成品根目录。
Directory mangaDramaRoot(AudioProductionHost appModel) =>
    Directory(p.join(appModel.databaseDirectory.path, 'manga_drama'));

/// 一卷的广播剧成品清单文件。
File mangaDramaManifestFile(AudioProductionHost appModel, String bookKey) =>
    MangaRenderManifest.fileFor(mangaDramaRoot(appModel), bookKey);
