/// 「按系列跑」：按系列顺序给每本书 / 每卷漫画标注（逐本串行）和 / 或排制作任务
/// （进现有的 [TtsRenderQueue]，由队列自己一本本做）。小说与漫画共用这一个运行：
/// [TtsSeriesRun.kind] 决定每本怎么标注（小说 = 逐章标说话人 [annotateTtsCast]；漫画 =
/// 三遍看图标注 [MangaAudioAnnotateSession]）、排哪种任务（[TtsRenderJobKind]）。
///
/// 一次只跑一个（[activeTtsSeriesRun]），离开制作台不中断；制作台订阅它显示进度。
/// 标注时每本书的角色表学回系列（经 `SeriesCastStore.update` 串行写入），后面的书接着
/// 用前面认出的人。某本标注失败就跳过它、不排它的生成；整体性失败（没配 AI、鉴权、
/// 取消）停下整个运行。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_annotator.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 按系列跑做哪几步。
enum TtsSeriesRunMode {
  annotate,
  render,
  both;

  bool get annotates => this != TtsSeriesRunMode.render;
  bool get renders => this != TtsSeriesRunMode.annotate;
}

/// 制作任务的参数（与制作台「开始制作」同一套）。
typedef TtsSeriesRenderOptions = ({
  String presetId,
  bool verify,
  String pausePreset,
  bool normalizeLoudness,
});

/// 一本书没做成的原因（标注失败码 / `book_missing` / `internal`）。
typedef TtsSeriesRunFailure = ({String bookKey, String code});

/// 标注失败里哪些是整体性的（后面的书也必然失败），遇到就停下整个运行。漫画标注的
/// 中止（[MangaAnnotateAbort]：鉴权 / 4xx 这类非临时失败）记成 `abort:<码>`，同样停下。
bool ttsSeriesRunStopsOn(String code) =>
    code == 'no_ai_provider' ||
    code == 'cancelled' ||
    code.startsWith(kTtsSeriesRunAbortPrefix);

const String kTtsSeriesRunAbortPrefix = 'abort:';

/// 漫画卷标注后还有失败页（记在标注账本里，复核界面可重试）：不排它的生成。
const String kTtsSeriesRunMangaIncomplete = 'manga_annotate_incomplete';

TtsSeriesRun? _active;

/// 正在跑（或刚跑完、还没被新运行替换）的按系列跑。
TtsSeriesRun? get activeTtsSeriesRun => _active;

class TtsSeriesRun extends ChangeNotifier {
  TtsSeriesRun._({
    required this.appModel,
    required this.seriesKey,
    required this.books,
    required this.mode,
    required this.render,
    required this.kind,
  });

  /// 开始一次按系列跑；已有在跑的直接返回那个。
  static TtsSeriesRun start({
    required AppModel appModel,
    required String seriesKey,
    required List<String> books,
    required TtsSeriesRunMode mode,
    required TtsSeriesRenderOptions render,
    TtsRenderJobKind kind = TtsRenderJobKind.book,
  }) {
    final TtsSeriesRun? running = _active;
    if (running != null && running.running) return running;
    final TtsSeriesRun run = TtsSeriesRun._(
      appModel: appModel,
      seriesKey: seriesKey,
      books: List<String>.unmodifiable(books),
      mode: mode,
      render: render,
      kind: kind,
    );
    _active = run;
    run._future = run._run();
    return run;
  }

  final AppModel appModel;
  final String seriesKey;
  final List<String> books;
  final TtsSeriesRunMode mode;
  final TtsSeriesRenderOptions render;

  /// 小说（[TtsRenderJobKind.book]）还是漫画（[TtsRenderJobKind.manga]）。
  final TtsRenderJobKind kind;

  Future<void>? _future;
  bool _cancelled = false;
  bool running = true;

  /// 正在处理第几本（0 起）。
  int index = 0;

  /// 当前这本的标题。
  String title = '';

  /// 当前这本标注进度（章）。
  int annotateDone = 0;
  int annotateTotal = 0;

  /// 已排进制作队列的书。
  final List<String> queued = <String>[];
  final List<TtsSeriesRunFailure> failures = <TtsSeriesRunFailure>[];

  Future<void> get done => _future ?? Future<void>.value();

  void cancel() {
    _cancelled = true;
    notifyListeners();
  }

  bool get cancelled => _cancelled;

  Future<void> _run() =>
      kind == TtsRenderJobKind.manga ? _runManga() : _runBooks();

  /// 漫画：逐卷看图标注（只标还没标过的页），再排整卷生成任务。
  Future<void> _runManga() async {
    final TtsRenderQueue queue = ttsRenderQueueFor(appModel);
    final AiProviderConfig? provider = mode.annotates
        ? resolveMangaAudioProvider(appModel)
        : null;
    try {
      if (mode.annotates && provider == null) {
        failures.add((bookKey: seriesKey, code: 'no_ai_provider'));
        return;
      }
      for (index = 0; index < books.length; index++) {
        if (_cancelled) break;
        final String bookKey = books[index];
        annotateDone = 0;
        annotateTotal = 0;
        final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
        if (row == null) {
          failures.add((bookKey: bookKey, code: 'book_missing'));
          notifyListeners();
          continue;
        }
        title = row.title.isEmpty ? bookKey : row.title;
        notifyListeners();
        if (provider != null) {
          final String? code = await _annotateManga(bookKey, provider);
          if (code != null) {
            failures.add((bookKey: bookKey, code: code));
            notifyListeners();
            if (ttsSeriesRunStopsOn(code)) break;
            continue;
          }
        }
        if (mode.renders && !_cancelled) {
          final MangaAudioVolume? volume = await loadMangaAudioVolume(
            appModel,
            bookKey,
          );
          final String? blocker = volume == null
              ? 'book_missing'
              : mangaRenderBlocker(volume);
          if (blocker != null) {
            failures.add((bookKey: bookKey, code: blocker));
            notifyListeners();
            continue;
          }
          await queue.enqueue(
            bookKey: bookKey,
            title: title,
            presetId: render.presetId,
            kind: TtsRenderJobKind.manga,
          );
          queued.add(bookKey);
          notifyListeners();
        }
      }
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// 标注一卷；返回失败码，成功 null。
  Future<String?> _annotateManga(
    String bookKey,
    AiProviderConfig provider,
  ) async {
    try {
      final MangaAudioAnnotateSession session =
          await MangaAudioAnnotateSession.open(appModel, bookKey);
      final MangaAnnotateRunSummary summary = await session.annotate(
        provider: provider,
        pages: session.pagesToAnnotate(),
        // 已经标过角色表的卷（有已标页）不再重跑角色表那一遍。
        withRoster: session.script.annotatedPages.isEmpty || session.isStale,
        isCancelled: () => _cancelled,
        onProgress: (MangaAnnotatePhase phase, int done, int total) {
          annotateDone = done;
          annotateTotal = total;
          notifyListeners();
        },
      );
      if (_cancelled) return 'cancelled';
      return summary.failedPages.isEmpty ? null : kTtsSeriesRunMangaIncomplete;
    } on MangaAudioAnnotateError catch (e) {
      return e.code;
    } on MangaAnnotateAbort catch (e) {
      return e.code == 'cancelled'
          ? 'cancelled'
          : '$kTtsSeriesRunAbortPrefix${e.code}';
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'TtsSeriesRun.annotateManga($bookKey)',
        e,
        stack,
      );
      return 'internal';
    }
  }

  Future<void> _runBooks() async {
    final TtsServices tts = TtsServices.of(appModel.prefsRepo);
    final TtsRenderQueue queue = ttsRenderQueueFor(appModel);
    try {
      for (index = 0; index < books.length; index++) {
        if (_cancelled) break;
        final String bookKey = books[index];
        annotateDone = 0;
        annotateTotal = 0;
        final ({EpubBookRow row, EpubBook book})? loaded =
            await loadEpubForStudio(appModel.database, bookKey);
        if (loaded == null) {
          failures.add((bookKey: bookKey, code: 'book_missing'));
          notifyListeners();
          continue;
        }
        title = loaded.row.title.isEmpty ? loaded.book.title : loaded.row.title;
        notifyListeners();
        if (mode.annotates) {
          final String? code = await _annotate(bookKey, loaded.book, tts);
          if (code != null) {
            failures.add((bookKey: bookKey, code: code));
            notifyListeners();
            if (ttsSeriesRunStopsOn(code)) break;
            // 标注没做完的书不排制作：多声优会用残缺的选角表念。
            continue;
          }
        }
        if (mode.renders && !_cancelled) {
          await queue.enqueue(
            bookKey: bookKey,
            title: title,
            presetId: render.presetId,
            verify: render.verify,
            pausePreset: render.pausePreset,
            normalizeLoudness: render.normalizeLoudness,
          );
          queued.add(bookKey);
          notifyListeners();
        }
      }
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// 标注一本（跳过已标的章）；返回失败码，成功 null。
  Future<String?> _annotate(
    String bookKey,
    EpubBook book,
    TtsServices tts,
  ) async {
    try {
      final TtsBookPlan plan = await buildStudioPlan(book, tts);
      await annotateTtsCast(
        appModel: appModel,
        bookKey: bookKey,
        plan: plan,
        onProgress: (int done, int total) {
          annotateDone = done;
          annotateTotal = total;
          notifyListeners();
        },
        isCancelled: () => _cancelled,
      );
      return null;
    } on TtsCastAnnotateFailure catch (e) {
      return e.code;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsSeriesRun.annotate($bookKey)', e, stack);
      return 'internal';
    }
  }
}
