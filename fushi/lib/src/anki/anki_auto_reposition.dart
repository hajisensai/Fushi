/// 制卡后自动按词频重排新卡——**调度层**（防抖 + 单飞，无 UI 依赖）。
///
/// 数据流：制卡成功 → [AnkiAutoRepositionScheduler.notifyMined] 收下**后端实际
/// 落卡的牌组名**（`MineOutcome.deckName`）→ 防抖窗口内的多次制卡合并成一批 →
/// 一次 `plan` + `apply` 把这批新卡排到正确位置 → 清理过期快照。
///
/// 触发点接在 `AutoRepositionAnkiRepository`（`auto_reposition_anki_repository.dart`）
/// 上，它包在 `ankiRepositoryProvider` 最外层，因此查词/阅读器/视频/漫画所有制卡
/// 入口都自动经过，无需逐个调用点改动。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';

/// 自动重排失败时报给用户的通道（生产实现是 toast）。
///
/// 注入而不是直接调 UI，是为了让本类保持无 Flutter widget 依赖、可纯 Dart 单测。
/// 只在**失败**时调用：成功是静默的——用户没点任何按钮，不该为此收到通知。
typedef AnkiAutoRepositionFailureReporter = void Function(String message);

/// 一次自动重排跑完的结果，仅供测试与诊断断言（生产路径不消费）。
@immutable
class AnkiAutoRepositionRun {
  const AnkiAutoRepositionRun({
    required this.deckName,
    required this.written,
    required this.skipped,
    required this.failed,
  });

  final String deckName;
  final int written;
  final int skipped;
  final int failed;
}

/// 制卡后自动重排的防抖调度器。
///
/// 三条不变式：
/// * **防抖**：窗口内的多次制卡只触发一次重排。一张卡一次全牌组重写既没必要
///   （位置是按整组算的），又会把 AnkiConnect 打满。
/// * **单飞**：同一时刻只有一次重排在跑。重排期间新来的牌组进 [_pending]，由
///   正在跑的那一轮的循环捡走，不并发——两次 `apply` 并发写同一牌组的位置，
///   后写的那份会基于过期的 `plan`。
/// * **静默**：只有失败才经 [_onFailure] 出声。
class AnkiAutoRepositionScheduler {
  AnkiAutoRepositionScheduler({
    required AnkiDeckRepositionRunner runner,
    required Future<AnkiSettings> Function() loadSettings,
    AnkiAutoRepositionFailureReporter? onFailure,
    Duration debounce = kDefaultDebounce,
    int snapshotsPerDeck = AnkiDeckRepositionRunner.kDefaultSnapshotsPerDeck,
  })  : _runner = runner,
        _loadSettings = loadSettings,
        _onFailure = onFailure,
        _debounce = debounce,
        _snapshotsPerDeck = snapshotsPerDeck;

  /// 默认防抖窗口。够长到把「连着挖十个词」合成一批，又短到用户切回 Anki
  /// 时位置已经排好。
  static const Duration kDefaultDebounce = Duration(seconds: 30);

  final AnkiDeckRepositionRunner _runner;
  final Future<AnkiSettings> Function() _loadSettings;
  final AnkiAutoRepositionFailureReporter? _onFailure;
  final Duration _debounce;
  final int _snapshotsPerDeck;

  final Set<String> _pending = <String>{};
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  /// 每跑完一个牌组回调一次，供测试观测。生产不接。
  @visibleForTesting
  void Function(AnkiAutoRepositionRun run)? onRunForTesting;

  /// 正在等防抖或正在跑（测试与诊断用）。
  bool get isIdle => _timer == null && !_running && _pending.isEmpty;

  /// 制卡成功后调用。[deckName] 是**后端实际落卡**的牌组名。
  ///
  /// 这里不查开关也不查后端支持：那两项要读设置（异步），而本方法在制卡的
  /// 返回路径上，必须是同步且极廉价的。真正的判据在 [_flush] 里、防抖窗口
  /// 到期后统一查一次——顺带让「制卡途中把开关关掉」立即生效。
  void notifyMined(String deckName) {
    if (_disposed || deckName.isEmpty) return;
    _pending.add(deckName);
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      _timer = null;
      unawaited(_flush());
    });
  }

  /// 立刻跑掉待办（跳过剩余防抖）。设置页关掉开关前的收尾、测试用。
  Future<void> flushNow() {
    _timer?.cancel();
    _timer = null;
    return _flush();
  }

  Future<void> _flush() async {
    // 单飞：已经在跑就直接返回。待办已经进了 [_pending]，正在跑的那轮的
    // while 会捡走——`_pending` 的读取与清空之间没有 await，不会漏。
    if (_disposed || _running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final List<String> decks = _pending.toList()..sort();
        _pending.clear();
        final AnkiSettings settings = await _loadSettings();
        // 开关与后端支持每轮都重新判：用户可能在防抖窗口里关掉开关，或者
        // 「制卡到已配对设备」把仓库换成了没有卡片级读写的那种。
        if (!settings.autoRepositionEnabled) return;
        if (!_runner.isSupported) return;
        final AnkiRepositionRankOptions options =
            AnkiRepositionRankOptions.fromSettings(settings);
        for (final String deck in decks) {
          if (_disposed) return;
          await _runDeck(deck, settings, options);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _runDeck(
    String deckName,
    AnkiSettings settings,
    AnkiRepositionRankOptions options,
  ) async {
    try {
      final AnkiRepositionPlan? plan = await _runner.plan(
        deckName: deckName,
        settings: settings,
        options: options,
      );
      // plan == null：后端不支持（已在 _flush 里挡过，这里是兜底）。
      // updates 为空：位置本来就是对的，不写、也不留快照。
      if (plan == null || plan.updates.isEmpty) return;
      final AnkiRepositionOutcome outcome = await _runner.apply(plan);
      onRunForTesting?.call(
        AnkiAutoRepositionRun(
          deckName: deckName,
          written: outcome.written,
          skipped: outcome.skipped,
          failed: outcome.failures.length,
        ),
      );
      if (outcome.failures.isNotEmpty) {
        _onFailure?.call(
          'Auto reposition: ${outcome.failures.length} of '
          '${plan.updates.length} cards in "$deckName" could not be moved.',
        );
      }
      await _runner.pruneSnapshots(keep: _snapshotsPerDeck);
    } on AnkiRepositionCancelled {
      // 自动路径没有取消按钮，走到这里只可能是 runner 内部的兜底；不打扰用户。
      return;
    } catch (e, stack) {
      debugPrint('AnkiAutoRepositionScheduler: $deckName failed: $e\n$stack');
      _onFailure?.call('Auto reposition failed for "$deckName": $e');
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
