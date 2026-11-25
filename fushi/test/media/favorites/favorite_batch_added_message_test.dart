import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_runner.dart';
import 'package:fushi_anki/fushi_anki.dart' show MineOutcome;

/// BUG-4287：收藏夹批量制卡不弹逐张结果提示，「保存到」被主机退回默认的提示
/// （[MineOutcome.notice]）只能挂在批量列表那一行上；此前只带音频缺失原因，提示被丢掉。
void main() {
  test('plain success carries no message', () {
    expect(favoriteBatchAddedMessage(const MineOutcome.success()), isNull);
  });

  test('notice from the landing reaches the batch row', () {
    expect(
      favoriteBatchAddedMessage(
        const MineOutcome.success(notice: 'Save to was reset'),
      ),
      'Save to was reset',
    );
  });

  test('audio warning and notice are both shown', () {
    expect(
      favoriteBatchAddedMessage(
        const MineOutcome.success(
          audioWarning: 'audio 404',
          notice: 'Save to was reset',
        ),
      ),
      'audio 404\nSave to was reset',
    );
  });

  test('empty strings are treated as absent', () {
    expect(
      favoriteBatchAddedMessage(
        const MineOutcome.success(audioWarning: '', notice: ''),
      ),
      isNull,
    );
  });
}
