import 'package:fushi_server/src/admin/pair_link_qr.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

/// 从 [pairLinkQrSvg] 的路径把深色模块还原成网格（含静区偏移），用来和 `package:qr`
/// 对同一条链接算出的模块逐格比对。
Set<(int, int)> _darkCells(String svg) {
  final String d = RegExp(
    r'<path fill="#000" d="([^"]*)"',
  ).firstMatch(svg)![1]!;
  final Set<(int, int)> cells = <(int, int)>{};
  for (final RegExpMatch m in RegExp(
    r'M(\d+),(\d+)h(\d+)v1h-\d+z',
  ).allMatches(d)) {
    final int x = int.parse(m[1]!), y = int.parse(m[2]!), w = int.parse(m[3]!);
    for (int i = 0; i < w; i++) {
      cells.add((y, x + i));
    }
  }
  return cells;
}

void main() {
  const String link =
      'fushi://pair?v=1&h=abcdef&a=https%3A%2F%2Ffushi.example.com&k=0123456789abcdef.0123456789abcdef0123456789abcdef';

  test('二维码 SVG 恰好编码这条链接：模块与 package:qr 逐格一致，含 4 格静区、白底', () {
    final String svg = pairLinkQrSvg(link);
    final QrImage img = QrImage(
      QrCode.fromData(data: link, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final int size = img.moduleCount + 8;
    expect(svg, contains('viewBox="0 0 $size $size"'));
    expect(svg, contains('fill="#fff"'));
    final Set<(int, int)> expected = <(int, int)>{
      for (int r = 0; r < img.moduleCount; r++)
        for (int c = 0; c < img.moduleCount; c++)
          if (img.isDark(r, c)) (r + 4, c + 4),
    };
    expect(_darkCells(svg), expected);
  });

  test('不同链接得到不同二维码', () {
    expect(pairLinkQrSvg(link), isNot(pairLinkQrSvg('${link}x')));
  });

  group('pairLinkNeedsPublicAddress', () {
    bool needs(List<String> pub, List<String> addrs) =>
        pairLinkNeedsPublicAddress(publicUrls: pub, addressUrls: addrs);

    test('没配公网地址且全是 Docker 桥接 / 回环 / 链路本地 -> true', () {
      expect(
        needs(const <String>[], <String>['https://172.17.0.2:48765']),
        isTrue,
      );
      expect(
        needs(const <String>[], <String>[
          'https://172.18.0.3:1',
          'https://127.0.0.1:1',
          'https://169.254.1.1:1',
          'https://[::1]:1',
        ]),
        isTrue,
      );
    });

    test('配了公网地址 -> false', () {
      expect(
        needs(
          <String>['https://x.example.com'],
          <String>['https://172.17.0.2:1'],
        ),
        isFalse,
      );
    });

    test('有任何一条可达地址（LAN / 域名 / p2p）-> false', () {
      expect(
        needs(const <String>[], <String>[
          'https://172.17.0.2:1',
          'https://192.168.1.5:1',
        ]),
        isFalse,
      );
      expect(
        needs(const <String>[], <String>['https://172.17.0.2:1', 'p2p://abc']),
        isFalse,
      );
      expect(
        needs(const <String>[], <String>['https://nas.example.com:1']),
        isFalse,
      );
      expect(
        needs(const <String>[], <String>['https://172.32.0.1:1']),
        isFalse,
      );
    });

    test('没有地址 -> false（那是 no_reachable_address 的事）', () {
      expect(needs(const <String>[], const <String>[]), isFalse);
    });
  });
}
