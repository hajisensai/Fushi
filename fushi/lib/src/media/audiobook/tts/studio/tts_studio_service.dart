/// 有声书制作台的应用级装配：任务队列单例 + 制作台与制作流程共用的计划构建。
///
/// 计划必须两边同一口径（同一份 maxLength、同一份发音词典）：校对结果里的句序、
/// 单句重新生成都按计划下标指认句子，口径漂开就指到别的句子上。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_runner.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/models/app_model.dart';

TtsRenderQueue? _queue;

/// 全应用唯一的制作队列（首次取用时从清单恢复并开始处理）。
TtsRenderQueue ttsRenderQueueFor(AppModel appModel) {
  final TtsRenderQueue? existing = _queue;
  if (existing != null) return existing;
  final TtsRenderQueue queue = TtsRenderQueue(
    store: File(
      p.join(appModel.databaseDirectory.path, 'tts_render_jobs.json'),
    ),
    workRoot: ttsRenderWorkRoot(appModel),
    runner: AppTtsRenderRunner(appModel: appModel),
  );
  _queue = queue;
  queue.load();
  return queue;
}

/// 制作任务的工作目录根（每个任务一个子目录，放按章编码的成品与校对产物）。
Directory ttsRenderWorkRoot(AppModel appModel) =>
    Directory(p.join(appModel.databaseDirectory.path, 'tts_render'));

/// 每本书的选角表（多声优配音）：`<db>/tts_cast/`。
TtsCastStore ttsCastStoreFor(AppModel appModel) => TtsCastStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// 书架行 → EPUB（只认 epub 格式且解包目录还在）。
Future<({EpubBookRow row, EpubBook book})?> loadEpubForStudio(
  FushiDatabase db,
  String bookKey,
) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null || BookFormat.parseOrEpub(row.format) != BookFormat.epub) {
    return null;
  }
  final String extractDir = row.extractDir;
  if (extractDir.isEmpty || !Directory(extractDir).existsSync()) return null;
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return (row: row, book: book);
}

/// 制作用的单句长度上限：固定值，不随声音变。多声优配音时一本书里混用好几种引擎，
/// 分句口径必须与声音无关，选角表与校对结果的句子才指得准；取各引擎上限里最小的
/// 那一档（GPT-SoVITS 120）。
const int kStudioSentenceMaxLength = 120;

/// 制作台与制作流程共用的整书计划。
Future<TtsBookPlan> buildStudioPlan(EpubBook book, TtsServices tts) =>
    buildTtsBookPlan(
      book,
      maxLength: kStudioSentenceMaxLength,
      pronunciation: tts.pronunciation.load(),
    );
