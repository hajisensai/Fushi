/// 多声优配音：每句用哪份声音预设，以及合成的并发闸门。
library;

import 'dart:async';
import 'dart:collection';

import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// [indices] 里每句（计划下标）的预设 id：选角表给了就用选角表的，否则任务的默认
/// 声音 [defaultPresetId]（旁白 / 没分配声音的角色 / 没标注的句子）。
Map<int, String> resolveTtsSentencePresets({
  required List<TtsPlanSentence> sentences,
  required Iterable<int> indices,
  required TtsCast cast,
  required String defaultPresetId,
}) => <int, String>{
  for (final int i in indices)
    i:
        cast.presetFor(sentences[i].section, sentences[i].matchStart) ??
        defaultPresetId,
};

/// 计数信号量：同时最多 [capacity] 个持有者，其余按先来后到排队。
class TtsRenderGate {
  TtsRenderGate(this.capacity) : assert(capacity > 0);

  final int capacity;
  int _held = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_held < capacity) {
      _held++;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // 名额直接转给队首，持有数不变。
      _waiters.removeFirst().complete();
    } else {
      _held--;
    }
  }
}

/// 整个任务同时在途的合成请求上限（各引擎自己的上限之外再加一道总闸）。
const int kTtsRenderMaxParallel = 8;
