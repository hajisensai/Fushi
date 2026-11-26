import 'dart:io';

import 'package:qr/qr.dart';

/// 配对链接的二维码与可达性判断（纯函数，不依赖 host / Flutter）。
///
/// 二维码在服务端用纯 Dart 的 `package:qr` 渲染成内联 SVG：WebUI 不引第三方脚本，
/// 也不多一次请求，链接与二维码出自同一次签发，天然同步。

/// 静区宽度（模块数）：QR 规范要求 4。
const int _quietZone = 4;

/// 把 [data] 编成二维码 SVG：白底深色模块、含静区，与页面主题无关（扫码器要对比度）。
///
/// 纠错等级用 M（链接较长，L/M 才能保持模块够大；M 比 L 多一点容错）。每行相邻的
/// 深色模块合并成一段 `h` 路径，体积远小于逐模块一个 `<rect>`。
String pairLinkQrSvg(String data) {
  final QrCode code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final QrImage image = QrImage(code);
  final int n = image.moduleCount;
  final int size = n + _quietZone * 2;
  final StringBuffer path = StringBuffer();
  for (int r = 0; r < n; r++) {
    int c = 0;
    while (c < n) {
      if (!image.isDark(r, c)) {
        c++;
        continue;
      }
      final int start = c;
      while (c < n && image.isDark(r, c)) {
        c++;
      }
      path.write(
        'M${start + _quietZone},${r + _quietZone}h${c - start}v1h-${c - start}z',
      );
    }
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" '
      'shape-rendering="crispEdges" role="img">'
      '<rect width="$size" height="$size" fill="#fff"/>'
      '<path fill="#000" d="$path"/></svg>';
}

/// 链接里的地址是否全部不可能被另一台设备（手机）连上，且用户没配公网地址。
///
/// Docker 桥接模式下容器只看得到 172.x 桥接地址；回环、链路本地同理。只要
/// [publicUrls] 非空（用户已声明对外地址）或有任何一条地址不属于这三类
/// （含 `p2p://` 与域名），就不报。没有地址时也不报（那是 no_reachable_address 的事）。
bool pairLinkNeedsPublicAddress({
  required List<String> publicUrls,
  required List<String> addressUrls,
}) {
  if (publicUrls.isNotEmpty || addressUrls.isEmpty) return false;
  return addressUrls.every(_isUnreachableFromOtherDevices);
}

bool _isUnreachableFromOtherDevices(String url) {
  final String host = Uri.tryParse(url)?.host ?? '';
  final InternetAddress? ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  if (ip.type == InternetAddressType.IPv4) {
    final List<int> b = ip.rawAddress;
    // 172.16.0.0/12：Docker 默认桥接网段（172.17/16 起）所在的私网块。
    return b[0] == 172 && b[1] >= 16 && b[1] <= 31;
  }
  return false;
}
