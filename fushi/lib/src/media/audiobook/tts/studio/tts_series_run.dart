/// 「按系列跑」：按系列顺序给每本书标注说话人（逐本、逐章，串行）和 / 或排制作任务
/// （进现有的 [TtsRenderQueue]，由队列自己一本本做）。
///
/// 一次只跑一个（[activeTtsSeriesRun]），离开制作台不中断；制作台订阅它显示进度。
/// 标注时每本书的角色表学回系列（[annotateTtsCast] 负责），后面的书接着用前面认出的人。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

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

/// 标注失败里哪些是整体性的（后面的书也必然失败），遇到就停下整个运行。
bool ttsSeriesRunStopsOn(String code) =>
    code == 'no_ai_provider' || code == 'cancelled';

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
  });

  /// 开始一次按系列跑；已有在跑的直接返回那个。
  static TtsSeriesRun start({
    required AppModel appModel,
    required String seriesKey,
    required List<String> books,
    required TtsSeriesRunMode mode,
    required TtsSeriesRenderOptions render,
  }) {
    final TtsSeriesRun? running = _active;
    if (running != null && running.running) return running;
    final TtsSeriesRun run = TtsSeriesRun._(
      appModel: appModel,
      seriesKey: seriesKey,
      books: List<String>.unmodifiable(books),
      mode: mode,
      render: render,
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

  Future<void> _run() async {
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
