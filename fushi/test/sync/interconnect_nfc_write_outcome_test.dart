import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';

/// NFC 贴纸写入的原生返回值是字符串三态（NfcTagWriterChannelHandler.java）。
/// 「要求锁定却只写入」必须单独提示：用户以为贴纸防改写了而实际没有，是最坏的结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('原生返回值映射；未知值与 null 一律按失败', () {
    expect(
      parseInterconnectNfcWriteOutcome('locked'),
      InterconnectNfcWriteOutcome.locked,
    );
    expect(
      parseInterconnectNfcWriteOutcome('written'),
      InterconnectNfcWriteOutcome.written,
    );
    expect(
      parseInterconnectNfcWriteOutcome('failed'),
      InterconnectNfcWriteOutcome.failed,
    );
    // 旧原生实现回的是 bool：true 不能被当成「已锁定」。
    expect(
      parseInterconnectNfcWriteOutcome(true),
      InterconnectNfcWriteOutcome.failed,
    );
    expect(
      parseInterconnectNfcWriteOutcome(null),
      InterconnectNfcWriteOutcome.failed,
    );
  });

  test('要求锁定但芯片不支持 → 专门的提示，不是「已写入」', () {
    expect(
      interconnectNfcWriteMessage(
        InterconnectNfcWriteOutcome.written,
        lockRequested: true,
      ),
      t.sync_pair_nfc_lock_unsupported,
    );
    expect(
      interconnectNfcWriteMessage(
        InterconnectNfcWriteOutcome.written,
        lockRequested: false,
      ),
      t.sync_pair_nfc_written,
    );
    expect(
      interconnectNfcWriteMessage(
        InterconnectNfcWriteOutcome.locked,
        lockRequested: true,
      ),
      t.sync_pair_nfc_written_locked,
    );
    expect(
      interconnectNfcWriteMessage(
        InterconnectNfcWriteOutcome.failed,
        lockRequested: true,
      ),
      t.sync_pair_nfc_failed,
    );
  });
}
