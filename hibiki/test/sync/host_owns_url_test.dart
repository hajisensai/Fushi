import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';

/// BUG-1004 断点B 守卫：`hostOwnsUrl` 判定单词音频 URL 是否指向当前互联 host（同源）。
/// 命中的（host 自签 https `…/api/lookup/audio/file?id=…`）落卡时才改经已钉扎/鉴权通道
/// 下载，绕开裸 HttpClient 对自签证书握手失败；公网源（forvo 有效证书）不动。
void main() {
  const String base = 'https://192.168.1.34:38765';

  test('同源（scheme+host+port 全一致）→ true', () {
    expect(
        HibikiClientSyncBackend.hostOwnsUrl(
            base, '$base/api/lookup/audio/file?id=tok'),
        true);
  });

  test('不同 host / port / scheme → false', () {
    expect(
        HibikiClientSyncBackend.hostOwnsUrl(
            base, 'https://192.168.1.99:38765/api/lookup/audio/file?id=t'),
        false);
    expect(
        HibikiClientSyncBackend.hostOwnsUrl(
            base, 'https://192.168.1.34:9999/api/lookup/audio/file?id=t'),
        false);
    expect(
        HibikiClientSyncBackend.hostOwnsUrl(
            base, 'http://192.168.1.34:38765/api/lookup/audio/file?id=t'),
        false);
  });

  test('公网 forvo（外源，有效证书）→ false（不拦截、直连下载）', () {
    expect(
        HibikiClientSyncBackend.hostOwnsUrl(
            base, 'https://apifree.forvo.com/audio/xyz.mp3'),
        false);
  });

  test('base 为 null/空 / url 畸形无 scheme → false', () {
    expect(HibikiClientSyncBackend.hostOwnsUrl(null, '$base/x'), false);
    expect(HibikiClientSyncBackend.hostOwnsUrl('', '$base/x'), false);
    expect(HibikiClientSyncBackend.hostOwnsUrl(base, '/relative/path'), false);
  });
}
