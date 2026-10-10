import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';

/// BUG-3236：互联 host 的蓝光标题交给 libmpv 的是 `edl://`，每段是 host 的流 URL。
/// 整串 EDL 不是 URL，`nativePlaybackUri` 必须逐段改写——否则自签 https 段直接落到
/// libmpv 自己做 TLS（BUG-2455），播放器打不开。
void main() {
  tearDown(() {
    // 明文 http 撤销同 (host, port) 的 TLS 登记，免得串到别的用例。
    nativePlaybackUri('http://host.test:9443/');
  });

  test('https 段降成显式端口的 http 并登记中继终结 TLS；本地段与起止原样', () {
    const String local = r'D:\Disc\BDMV\STREAM\00001.m2ts';
    final String edl = buildBlurayEdlUri(<BlurayEdlSegment>[
      (
        source:
            'https://host.test:9443/api/library/videos/d/bdclip.m2ts?token=t&n=0',
        inTimeTicks: 468000,
        durationTicks: 54000,
      ),
      (source: local, inTimeTicks: 504000, durationTicks: 72000),
    ]);
    final String native = nativePlaybackUri(edl);
    expect(decodeEdlSources(native), <String>[
      'http://host.test:9443/api/library/videos/d/bdclip.m2ts?token=t&n=0',
      local,
    ]);
    expect(isTlsNativeOrigin('host.test', 9443), isTrue);
    // 起止逐字保留：与改写前的 EDL 只差来源字段。
    expect(native, contains(',10.400000,1.200000;'));
    expect(native, contains(',11.200000,1.600000;'));
  });

  test('非 https 的 EDL 原样返回', () {
    final String edl = buildBlurayEdlUri(<BlurayEdlSegment>[
      (
        source: 'http://127.0.0.1:1/x.m2ts',
        inTimeTicks: 0,
        durationTicks: 45000,
      ),
    ]);
    expect(nativePlaybackUri(edl), edl);
  });
}
