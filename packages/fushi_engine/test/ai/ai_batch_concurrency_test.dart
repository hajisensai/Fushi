// 反馈 49c93dxKoA：转录稿 AI 校对并发写死为 2。批量校对的并发改由提供商推算
// （AiProviderConfig.batchConcurrency），视频字幕校对与转录稿校对同一个口径。
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:test/test.dart';

AiProviderConfig _provider({
  List<String> keys = const <String>['k1'],
  int rpm = 0,
}) => AiProviderConfig(
  id: 'p',
  presetId: 'custom',
  name: 'p',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  apiKeys: <AiApiKey>[for (final String k in keys) AiApiKey(k)],
  model: 'm',
  requestsPerMinute: rpm,
);

void main() {
  test('单 key、不限速：与视频字幕校对原默认一致（4）', () {
    expect(_provider().batchConcurrency, kAiBatchConcurrencyPerKey);
  });

  test('多 key 按把数放大，封顶', () {
    expect(_provider(keys: <String>['a', 'b']).batchConcurrency, 8);
    expect(
      _provider(keys: <String>['a', 'b', 'c', 'd', 'e']).batchConcurrency,
      kAiBatchConcurrencyMax,
    );
  });

  test('本地服务没 key 也至少按一把算', () {
    expect(_provider(keys: const <String>[]).batchConcurrency, 4);
  });

  test('填了每分钟上限时按 rpm 压低，至少 1', () {
    expect(_provider(rpm: 12).batchConcurrency, 2);
    expect(_provider(rpm: 3).batchConcurrency, 1);
    expect(_provider(keys: <String>['a', 'b'], rpm: 600).batchConcurrency, 8);
  });
}
