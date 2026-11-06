import 'package:fushi_music/src/plugin/plugin_instance.dart';
import 'package:test/test.dart';

void main() {
  test('在途响应缓冲预算：超额拒绝且不占额度，归还后可再用', () {
    final MusicPluginResponseBudget b = MusicPluginResponseBudget(100);
    expect(b.tryReserve(60), isTrue);
    expect(b.tryReserve(50), isFalse, reason: '60 + 50 > 100');
    expect(b.used, 60, reason: '失败的占用不能计入');
    expect(b.tryReserve(40), isTrue);
    expect(b.used, 100);
    b.release(60);
    expect(b.tryReserve(50), isTrue);
    expect(b.used, 90);
  });

  test('实例级在途响应上限是 32 MiB', () {
    expect(kMusicPluginInflightResponseBytes, 32 * 1024 * 1024);
  });
}
