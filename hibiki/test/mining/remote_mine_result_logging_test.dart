import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/hibiki_remote_lookup_service.dart';
import 'package:fushi/utils.dart' show ErrorLogService;

/// TODO-1303：远端制卡（浏览器扩展）失败必须**写进错误日志 + 回带诊断**，不再只
/// `debugPrint` 进黑洞。`remoteMineResultFromOutcome` / `remoteMineError` 是那条真相路径：
/// 复用 app 内同一 `logMineFailure`（写完整诊断进 [ErrorLogService]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('error outcome -> RemoteMineResult error + 写进 ErrorLogService', () {
    final int before = ErrorLogService.instance.entries.length;
    final RemoteMineResult r =
        remoteMineResultFromOutcome(MineOutcome.failure('boom'));
    expect(r.result, 'error');
    expect(r.detail, 'boom');
    expect(r.message, isNotNull);
    expect(r.message!.isNotEmpty, isTrue);
    final entries = ErrorLogService.instance.entries;
    expect(entries.length, greaterThan(before));
    expect(entries.last.source, 'Anki.mineEntry');
    expect(entries.last.error, contains('boom'));
  });

  test('remoteMineError 写日志并回带 reason/detail', () {
    final int before = ErrorLogService.instance.entries.length;
    final RemoteMineResult r = remoteMineError(
      'Anki.mineImmersion.netflix',
      'Netflix 制卡失败：required audio missing',
      detail: 'required audio missing',
    );
    expect(r.result, 'error');
    expect(r.message, contains('required audio missing'));
    expect(r.detail, 'required audio missing');
    final entries = ErrorLogService.instance.entries;
    expect(entries.length, greaterThan(before));
    expect(entries.last.source, 'Anki.mineImmersion.netflix');
  });

  test('success + audioWarning -> message 带警告、result success（部分成功）', () {
    final RemoteMineResult r = remoteMineResultFromOutcome(
        const MineOutcome.success(audioWarning: 'audio 404'));
    expect(r.result, 'success');
    expect(r.message, 'audio 404');
    expect(r.detail, isNull);
  });

  test('纯成功 -> 无 message/detail', () {
    final RemoteMineResult r =
        remoteMineResultFromOutcome(const MineOutcome.success());
    expect(r.result, 'success');
    expect(r.message, isNull);
    expect(r.detail, isNull);
  });

  test('duplicate/notConfigured -> 结果名直出、不写错误日志', () {
    final int before = ErrorLogService.instance.entries.length;
    expect(remoteMineResultFromOutcome(const MineOutcome.duplicate()).result,
        'duplicate');
    expect(
        remoteMineResultFromOutcome(const MineOutcome.notConfigured()).result,
        'notConfigured');
    expect(ErrorLogService.instance.entries.length, before);
  });
}
