import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/torrent/magnet_utils.dart';
import 'package:fushi/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

/// BUG-1807：URL 归一化的**主防线在消费端**，不是输入框的 keyboardType。
///
/// 键盘类型只影响手输那一路；粘贴、扫码、从旧配置或同步回填读回来的值一样会带
/// 全角进来，那些路径根本不经过键盘。所以每个「把用户字符串变成地址」的函数
/// 都必须自己折全角——本文件逐个锁住这些入口。
///
/// 每组都成对断言：全角输入与半角输入得到**同一个**结果。只断言「全角不为 null」
/// 是不够的，那放得过「解析出一个不同的、错的地址」。
void main() {
  group('Jellyfin 服务器地址（JellyfinApi.normalizeServerUrl）', () {
    test('全角与半角归一到同一个地址', () {
      const String expected = 'http://192.168.1.10:8096';
      expect(JellyfinApi.normalizeServerUrl('http://192.168.1.10:8096'),
          expected);
      expect(JellyfinApi.normalizeServerUrl('http：//192.168.1.10:8096'),
          expected);
      expect(JellyfinApi.normalizeServerUrl('http://192。168。1。10:8096'),
          expected);
    });

    test('裸主机补 http scheme 的老行为不变', () {
      expect(JellyfinApi.normalizeServerUrl('192.168.1.10:8096'),
          'http://192.168.1.10:8096');
      // 全角裸主机同样要能补上
      expect(JellyfinApi.normalizeServerUrl('192。168。1。10:8096'),
          'http://192.168.1.10:8096');
    });

    test('去尾斜杠的老行为不变', () {
      expect(JellyfinApi.normalizeServerUrl('http://host:8096///'),
          'http://host:8096');
    });
  });

  group('AnkiConnect 主机（normalizeAnkiConnectHostInput）', () {
    test('全角 IP 折回半角，端口仍能拆出来', () {
      final ({String host, int? port, bool? useHttps}) full =
          normalizeAnkiConnectHostInput('192。168。1。5:8765');
      final ({String host, int? port, bool? useHttps}) half =
          normalizeAnkiConnectHostInput('192.168.1.5:8765');
      expect(full.host, half.host);
      expect(full.port, half.port);
      expect(half.host, '192.168.1.5');
      expect(half.port, 8765);
    });

    test('全角 scheme 仍能被识别并剥掉', () {
      final ({String host, int? port, bool? useHttps}) parsed =
          normalizeAnkiConnectHostInput('https：//anki.example.com:8765');
      expect(parsed.host, 'anki.example.com');
      expect(parsed.port, 8765);
      expect(parsed.useHttps, isTrue);
    });
  });

  group('下载代理 host:port（normalizeUserProxyHostPort）', () {
    test('全角与半角归一到同一结果', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:7890'), '127.0.0.1:7890');
      expect(normalizeUserProxyHostPort('127。0。0。1:7890'), '127.0.0.1:7890');
      expect(normalizeUserProxyHostPort('http：//127.0.0.1:7890'),
          '127.0.0.1:7890');
    });

    test('带路径仍然被拒——归一化不该放宽既有校验', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:7890/path'), isNull);
      // 全角斜杠折成半角后同样要被这条规则拦下，不能因为折过就放行。
      expect(normalizeUserProxyHostPort('127.0.0.1:7890／path'), isNull);
    });
  });

  group('磁力链（parseMagnetInfoHash）', () {
    const String hash = '0123456789abcdef0123456789abcdef01234567';

    test('全角冒号的磁力链仍能解析出 infoHash', () {
      expect(parseMagnetInfoHash('magnet:?xt=urn:btih:$hash'), hash);
      expect(parseMagnetInfoHash('magnet：?xt=urn:btih:$hash'), hash);
      expect(parseMagnetInfoHash('magnet：？xt＝urn：btih：$hash'), hash);
    });

    test('非磁力链仍返回 null——归一化不该让判据失效', () {
      expect(parseMagnetInfoHash('https://example.org/x.torrent'), isNull);
      expect(parseMagnetInfoHash(''), isNull);
    });
  });

  group('词典远端音频源（AudioSourcesDialog.isValidRemoteUrl）', () {
    test('全角地址模板不再被误判为非法', () {
      expect(
        AudioSourcesDialog.isValidRemoteUrl(
            'https://audio.example.org/?term={term}'),
        isTrue,
      );
      expect(
        AudioSourcesDialog.isValidRemoteUrl(
            'https：//audio.example.org/?term={term}'),
        isTrue,
      );
      expect(
        AudioSourcesDialog.isValidRemoteUrl(
            'https://audio。example。org/?term={term}'),
        isTrue,
      );
    });

    test('缺占位符 / 非 http scheme 仍被拒——既有规则不因归一化松动', () {
      expect(
        AudioSourcesDialog.isValidRemoteUrl('https://audio.example.org/'),
        isFalse,
      );
      expect(
        AudioSourcesDialog.isValidRemoteUrl('ftp://audio.example.org/{term}'),
        isFalse,
      );
    });
  });
}
