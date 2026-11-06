import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

/// Edge 二进制音频帧：2 字节大端头长 + 头 + 音频数据。
Uint8List _audioFrame(List<int> payload) {
  final List<int> header = ascii.encode(
    'X-RequestId:x\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n',
  );
  return Uint8List.fromList(<int>[
    header.length >> 8,
    header.length & 0xff,
    ...header,
    ...payload,
  ]);
}

const String _turnStart = 'X-RequestId:x\r\nPath:turn.start\r\n\r\n{}';
const String _turnEnd = 'X-RequestId:x\r\nPath:turn.end\r\n\r\n{}';

Matcher _failsWith(TtsFailureCode code, {String? detail}) => throwsA(
  isA<TtsFailure>()
      .having((TtsFailure f) => f.code, 'code', code)
      .having(
        (TtsFailure f) => detail == null || f.detail == detail,
        'detail matches',
        isTrue,
      ),
);

void main() {
  group('collectEdgeTurn', () {
    test('collects audio until turn.end', () async {
      final StreamController<Object?> socket = StreamController<Object?>();
      final Future<EdgeTurnResult> turn = collectEdgeTurn(
        socket.stream,
        cancel: TtsCancelToken(),
      );
      socket
        ..add(_turnStart)
        ..add(_audioFrame(<int>[1, 2, 3]))
        ..add(_audioFrame(<int>[4]))
        ..add(_turnEnd);
      final EdgeTurnResult result = await turn;
      expect(result.audio, <int>[1, 2, 3, 4]);
      await socket.close();
    });

    test('a half-open connection (no frames) fails fast as a transient '
        'network error and aborts the socket', () async {
      final StreamController<Object?> socket = StreamController<Object?>();
      bool aborted = false;
      final Stopwatch sw = Stopwatch()..start();
      final Future<EdgeTurnResult> turn = collectEdgeTurn(
        socket.stream,
        cancel: TtsCancelToken(),
        idleTimeout: const Duration(milliseconds: 80),
        onAbort: () => aborted = true,
      );
      socket.add(_turnStart);
      socket.add(_audioFrame(<int>[1]));
      // 之后再也没有帧：既不 turn.end 也不关连接。
      await expectLater(
        turn,
        _failsWith(TtsFailureCode.network, detail: 'idle'),
      );
      expect(aborted, isTrue);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(const TtsFailure(TtsFailureCode.network).isTransient, isTrue);
      await socket.close();
    });

    test('steady frames keep the idle timer alive', () async {
      final StreamController<Object?> socket = StreamController<Object?>();
      final Future<EdgeTurnResult> turn = collectEdgeTurn(
        socket.stream,
        cancel: TtsCancelToken(),
        idleTimeout: const Duration(milliseconds: 150),
      );
      // 总时长 ~400 ms 远超空闲时限，但每 40 ms 有一帧。
      for (int i = 0; i < 10; i++) {
        socket.add(_audioFrame(<int>[i]));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      socket.add(_turnEnd);
      final EdgeTurnResult result = await turn;
      expect(result.audio.length, 10);
      await socket.close();
    });

    test(
      'server closing before turn.end is a transient network failure',
      () async {
        final StreamController<Object?> socket = StreamController<Object?>();
        final Future<EdgeTurnResult> turn = collectEdgeTurn(
          socket.stream,
          cancel: TtsCancelToken(),
        );
        socket.add(_audioFrame(<int>[1]));
        final Future<void> expectation = expectLater(
          turn,
          _failsWith(TtsFailureCode.network, detail: 'closed early'),
        );
        await socket.close();
        await expectation;
      },
    );

    test('turn.end without audio is a transient bad response', () async {
      final StreamController<Object?> socket = StreamController<Object?>();
      final Future<EdgeTurnResult> turn = collectEdgeTurn(
        socket.stream,
        cancel: TtsCancelToken(),
      );
      socket.add(_turnEnd);
      try {
        await turn;
        fail('expected failure');
      } on TtsFailure catch (f) {
        expect(f.code, TtsFailureCode.badResponse);
        expect(f.detail, 'no audio');
        expect(f.isTransient, isTrue);
      }
      await socket.close();
    });

    test('cancel ends the turn as cancelled', () async {
      final StreamController<Object?> socket = StreamController<Object?>();
      final TtsCancelToken cancel = TtsCancelToken();
      bool aborted = false;
      final Future<EdgeTurnResult> turn = collectEdgeTurn(
        socket.stream,
        cancel: cancel,
        onAbort: () => aborted = true,
      );
      final Future<void> expectation = expectLater(
        turn,
        _failsWith(TtsFailureCode.cancelled),
      );
      cancel.cancel();
      await expectation;
      expect(aborted, isTrue);
      await socket.close();
    });
  });
}
