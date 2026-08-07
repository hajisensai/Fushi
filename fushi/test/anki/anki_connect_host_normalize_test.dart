import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';

/// BUG-971 守卫：AnkiConnect 主机字段规范化。
///
/// 旧逻辑对含 `/` 的输入静默拒绝保存，导致用户逐字符敲 `http://` 时，输入框失焦后
/// 回退到最后被接受的 `http:`（看起来「自动变成 http:」）。修复后 [normalizeAnkiConnectHostInput]
/// 把 URL 形态输入规范化成裸主机 + 可选端口，而不是拒斥。
void main() {
  group('normalizeAnkiConnectHostInput', () {
    test('裸主机原样保留，不带端口', () {
      final r = normalizeAnkiConnectHostInput('localhost');
      expect(r.host, 'localhost');
      expect(r.port, isNull);
    });

    test('剥掉 http:// scheme，得到裸主机', () {
      final r = normalizeAnkiConnectHostInput('http://localhost');
      expect(r.host, 'localhost');
      expect(r.port, isNull);
    });

    test('完整 URL：剥 scheme + path，拆出端口', () {
      final r = normalizeAnkiConnectHostInput('http://192.168.1.5:48765/foo');
      expect(r.host, '192.168.1.5');
      expect(r.port, 48765);
      expect(r.useHttps, isFalse);
    });

    test('https URL 保留安全协议，不静默降级为 HTTP', () {
      final r = normalizeAnkiConnectHostInput(
        'https://anki.example.com:443/path',
      );
      expect(r.host, 'anki.example.com');
      expect(r.port, 443);
      expect(r.useHttps, isTrue);
    });

    test('非 HTTP(S) scheme 被拒绝', () {
      final r = normalizeAnkiConnectHostInput('ftp://anki.example.com');
      expect(r.host, isEmpty);
      expect(r.port, isNull);
      expect(r.useHttps, isNull);
    });

    test('host:port 拆分到独立端口', () {
      final r = normalizeAnkiConnectHostInput('localhost:8765');
      expect(r.host, 'localhost');
      expect(r.port, 8765);
    });

    test('userinfo 被剥离', () {
      final r = normalizeAnkiConnectHostInput('http://user:pass@example.cn:80');
      expect(r.host, 'example.cn');
      expect(r.port, 80);
    });

    test('IDN 主机原样保留，不转 punycode / 不小写', () {
      final r = normalizeAnkiConnectHostInput('日本語.example.CN');
      expect(r.host, '日本語.example.CN');
      expect(r.port, isNull);
    });

    // BUG-971 的核心：打字途中的中间态绝不能塌成 "http:"。
    group('BUG-971 打字中间态不再塌成 http:', () {
      test('"http:" → "http"（尾部孤立冒号被剥，主机不残留冒号）', () {
        // 关键不是产出什么，而是这一步不再走「拒绝保存 → 失焦回退」的旧塌陷路径。
        expect(normalizeAnkiConnectHostInput('http:').host, 'http');
      });

      test('"http:/" 单斜杠 → "http"（斜杠截断 + 尾冒号剥离）', () {
        expect(normalizeAnkiConnectHostInput('http:/').host, 'http');
      });

      test('"http://"（scheme 完整但主机为空）→ 空主机，不写入', () {
        expect(normalizeAnkiConnectHostInput('http://').host, isEmpty);
      });

      test('"http://l" → "l"，最终收敛到真实主机', () {
        expect(normalizeAnkiConnectHostInput('http://l').host, 'l');
      });

      test('"http://localhost" 完整键入 → "localhost"', () {
        expect(normalizeAnkiConnectHostInput('http://localhost').host,
            'localhost');
      });
    });

    test('打字途中的孤立尾冒号 "localhost:" 不残留冒号', () {
      final r = normalizeAnkiConnectHostInput('localhost:');
      expect(r.host, 'localhost');
      expect(r.port, isNull);
    });

    test('越界数字端口被剥离但不设 port（主机不残留冒号）', () {
      final r = normalizeAnkiConnectHostInput('localhost:99999');
      expect(r.host, 'localhost');
      expect(r.port, isNull);
    });

    test('首尾空白被 trim', () {
      final r = normalizeAnkiConnectHostInput('  http://localhost:8765  ');
      expect(r.host, 'localhost');
      expect(r.port, 8765);
    });

    test('查询串 / fragment 被截断', () {
      expect(normalizeAnkiConnectHostInput('localhost?x=1').host, 'localhost');
      expect(normalizeAnkiConnectHostInput('localhost#frag').host, 'localhost');
    });
  });
}
