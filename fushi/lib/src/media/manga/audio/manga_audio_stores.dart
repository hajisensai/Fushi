/// 漫画有声的落盘位置（唯一一处定义；标注、有声书音源、生成、制作台都从这里取）。
///
/// - 演出稿、标注失败账本与小说选角表同目录（`<db>/tts_cast/`），后缀不同互不覆盖；
///   未配音账本与小说共用 `ttsVoicingStoreFor`（同目录同格式）；
/// - 成品在 `<db>/manga_audio/<sha1(bookKey)>/`（清单 + 每句一个文件）；
/// - 广播剧 / 动画音轨的成品在 `<db>/manga_drama/<sha1(bookKey)>/`（清单 + 每段一个
///   文件），与合成成品分开放：两者都能登记成这卷的有声成品，换来换去不互相清文件；
/// - `tts import` / 「导入漫画有声」登记的外部清单留在用户自己的目录里；单句重生成、
///   换本地音频、按角色重生成、补回、拿掉不读的句子都**原地改写**这份外部清单与它旁边
///   的音频（拍板 isATnQZ_eN-external），见 [mangaAudioEditTarget]。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show AudiobookRow;
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show audiobookRowHasRegistration;

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

/// 一卷「已生成成品」是哪一种。
enum MangaAudioProductKind {
  /// 本机生成的成品（[mangaRenderManifestFile]），没登记 / 登记的就是它都算这种。
  rendered,

  /// `tts import` 导入的外部清单：在用户自己的目录里原地改写。
  external,

  /// 登记的是广播剧 / 动画音轨成品（[mangaDramaManifestFile]）：句子不是按演出稿逐句
  /// 出的，不能按句改。
  drama,
}

/// 单句重生成 / 换本地音频 / 按角色重生成 / 补回 / 拿掉不读的句子改的那份成品清单。
/// 一卷只有一份真相源：登记的是哪份清单就改哪份（外部导入的原地改，不另存派生清单）。
class MangaAudioEditTarget {
  const MangaAudioEditTarget({required this.manifestFile, required this.kind});

  /// 按清单路径判定种类（撤销按操作当时记下的路径找回同一份清单）。
  factory MangaAudioEditTarget.forManifest(
    AudioProductionHost appModel,
    String bookKey,
    File manifestFile,
  ) {
    final String path = p.normalize(manifestFile.absolute.path);
    final MangaAudioProductKind kind;
    if (p.equals(
      path,
      p.normalize(mangaRenderManifestFile(appModel, bookKey).absolute.path),
    )) {
      kind = MangaAudioProductKind.rendered;
    } else if (p.equals(
      path,
      p.normalize(mangaDramaManifestFile(appModel, bookKey).absolute.path),
    )) {
      kind = MangaAudioProductKind.drama;
    } else {
      kind = MangaAudioProductKind.external;
    }
    return MangaAudioEditTarget(manifestFile: File(path), kind: kind);
  }

  final File manifestFile;
  final MangaAudioProductKind kind;

  bool get isExternal => kind == MangaAudioProductKind.external;

  /// 成品目录是不是 app 自己的（外部目录清扫只删 app 按句命名写出的文件）。
  bool get ownsDirectory => !isExternal;

  /// 改这份清单的生成器。
  MangaAudioRenderer renderer(MangaRenderBackend backend) => MangaAudioRenderer(
    backend: backend,
    manifestFile: manifestFile,
    ownsDirectory: ownsDirectory,
  );
}

/// [bookKey] 当前要改的成品：登记了漫画有声成品就是登记的那份（本机 / 外部；登记的是
/// 广播剧时仍改本机生成的那份、[MangaAudioEditTarget.kind] 记 drama），没登记（只生成
/// 没入库，或从没生成过）就是本机生成的那份。整卷生成不走这里（总是出到本机目录、整份
/// 登记，见 `runMangaRenderJob`）。
Future<MangaAudioEditTarget> mangaAudioEditTarget(
  AudioProductionHost appModel,
  String bookKey,
) async {
  final AudiobookRow? row = await appModel.database.getAudiobookByBookKey(
    bookKey,
  );
  if (row == null ||
      !audiobookRowHasRegistration(row) ||
      row.alignmentFormat != kMangaAlignmentFormat ||
      row.alignmentPath.isEmpty) {
    return MangaAudioEditTarget(
      manifestFile: mangaRenderManifestFile(appModel, bookKey),
      kind: MangaAudioProductKind.rendered,
    );
  }
  final MangaAudioEditTarget registered = MangaAudioEditTarget.forManifest(
    appModel,
    bookKey,
    File(row.alignmentPath),
  );
  if (registered.kind != MangaAudioProductKind.drama) return registered;
  // 广播剧成品不能按句改：改的仍是本机生成的那份（与登记广播剧之前一样），种类记成
  // drama 让调用方知道登记的不是它（ctl 据此 409）。
  return MangaAudioEditTarget(
    manifestFile: mangaRenderManifestFile(appModel, bookKey),
    kind: MangaAudioProductKind.drama,
  );
}
