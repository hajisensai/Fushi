import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/pending_mining/pending_mines_page.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi/src/anki/sync_client/anki_sync_client_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';

void main() {
  group('pendingFlushMessage：「全部发送」停下 / 失败时说清原因', () {
    test('连不上互联服务端：不再笼统报「连不上 Anki」', () {
      final String msg = pendingFlushMessage(
        PendingFlushReport(
          remaining: 3,
          unreachable: true,
          stopOutcome: MineOutcome.failure(
            'no paired device',
            errorCode: AnkiErrorCode.pairedDeviceUnreachable,
          ),
        ),
      );
      expect(msg, contains(t.anki_error_paired_device_unreachable));
      expect(msg, isNot(t.anki_pending_mines_unreachable));
    });

    test('Anki 未配置：说是未配置', () {
      final String msg = pendingFlushMessage(
        const PendingFlushReport(
          unreachable: true,
          stopOutcome: MineOutcome.notConfigured(),
        ),
      );
      expect(msg, contains(t.card_export_not_configured));
    });

    test('没有原因可说时退回旧文案', () {
      expect(
        pendingFlushMessage(const PendingFlushReport(unreachable: true)),
        t.anki_pending_mines_unreachable,
      );
    });

    test('有卡被拒收：汇总后附第一张的原因', () {
      final String msg = pendingFlushMessage(
        PendingFlushReport(
          delivered: 2,
          failed: 1,
          failureOutcome: MineOutcome.failure(
            'empty',
            errorCode: AnkiErrorCode.firstFieldEmpty,
          ),
        ),
      );
      expect(
        msg,
        startsWith(
          t.anki_pending_mines_flush_result(
            delivered: 2,
            failed: 1,
            remaining: 0,
          ),
        ),
      );
      expect(msg, contains(t.anki_error_first_field_empty));
    });
  });

  group('describeAnkiSyncError', () {
    const String raw =
        'SyncError { source: SyncError { info: "HttpError { code: 400, '
        "context: 'missing original size', source: None }\", kind: Other } }";

    test('missing original size → 说明回话的不是 Anki 同步服务，附原文', () {
      final String msg = describeAnkiSyncError(
        const FushiAnkiSyncException(raw),
      );
      expect(msg, contains('anki-original-size'));
      expect(msg, contains(raw));
    });

    test('认不出的错误原样给出、去掉异常类名', () {
      expect(
        describeAnkiSyncError(const FushiAnkiSyncException('boom')),
        'boom',
      );
      expect(describeAnkiSyncError('FushiAnkiSyncException: boom'), 'boom');
    });
  });
}
