// 设备可识别的纯函数：版本取 major.minor、各平台的默认名称、互联 host 认上传者的路径判据、对端名去品牌前缀、
// 冲突差异、设备显示名规则（「<名称>（Fushi X.Y）」/ 对端名 / 「未命名设备 · 最后在线」）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/pages/implementations/srs/srs_value_diff.dart';
import 'package:fushi/src/srs/srs_device_identity.dart';
import 'package:fushi/src/srs/srs_device_view.dart';
import 'package:fushi/src/srs/srs_directory_key.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  test('App 版本只取 major.minor', () {
    expect(srsAppVersionLabel('3.3.1+2200'), '3.3');
    expect(srsAppVersionLabel('10.12.0'), '10.12');
    expect(srsAppVersionLabel('dev'), 'dev');
  });

  test('默认名称：iOS 机型名、Android 厂商 + 型号、macOS 机型', () {
    expect(
      srsAppleMobileModelName('iPhone18,3', fallback: 'iPhone'),
      'iPhone 17',
    );
    expect(srsAppleMobileModelName('iPad16,3', fallback: 'iPad'), 'iPad');
    expect(srsAppleMobileModelName('arm64', fallback: 'iPhone'), 'iPhone');
    expect(srsAndroidModelName('Google', 'Pixel 8'), 'Google Pixel 8');
    expect(srsAndroidModelName('samsung', 'SM-S918B'), 'Samsung SM-S918B');
    expect(srsAndroidModelName('OnePlus', 'OnePlus PJD110'), 'OnePlus PJD110');
    expect(srsMacModelName('MacBookPro18,3'), 'MacBook Pro');
    expect(srsMacModelName('Mac15,12'), 'MacBook Air');
    expect(srsMacModelName('Mac99,1'), 'Mac');
  });

  test('host 只把作者自己的段算作上传者身份（转发件、head 不算）', () {
    const String dev = '0193a1b2-0000-7000-8000-00000000beef';
    const String root = 'fushi-data/fushi-srs/p1/v3/devices/$dev';
    expect(
      srsHostUploadedSegmentDevice(
        '$root/seg-000000000001-000000000002-0a1b2c3d.bin',
      ),
      dev,
    );
    expect(
      srsHostUploadedSegmentDevice(
        '$root/rly-000000000001-000000000002-0a1b2c3d.bin',
      ),
      isNull,
    );
    expect(
      srsHostUploadedSegmentDevice('$root/head-000000000003-0a1b2c3d.json'),
      isNull,
    );
    expect(
      srsHostUploadedSegmentDevice('fushi-data/other/devices/$dev/seg-1.bin'),
      isNull,
    );
  });

  test('对端名去掉品牌前缀', () {
    expect(interconnectPeerDisplayName('Fushi · iPhone'), 'iPhone');
    expect(interconnectPeerDisplayName('Hibiki · Pixel 8'), 'Pixel 8');
    expect(interconnectPeerDisplayName('Fushi'), 'Fushi');
  });

  test('差异：被替换一边独有的划掉、当前一边独有的高亮', () {
    expect(srsDiffSegments('今日は雨', '今日は晴れ'), <(SrsDiffOp, String)>[
      (SrsDiffOp.same, '今日は'),
      (SrsDiffOp.removed, '雨'),
      (SrsDiffOp.added, '晴れ'),
    ]);
    expect(srsDiffSegments('a' * (kSrsDiffMaxChars + 1), 'b'), isNull);
  });

  test('元信息分隔：全角收尾标点后只接「· 」，其余照旧「 · 」，空段跳过', () {
    expect(
      SrsMetaLine.join(<String>['iPhone 17（Fushi 3.3）', '2026-11-04']),
      'iPhone 17（Fushi 3.3）· 2026-11-04',
    );
    expect(
      SrsMetaLine.join(<String>['iPhone 17 (Fushi 3.3)', '', '2026-11-04']),
      'iPhone 17 (Fushi 3.3) · 2026-11-04',
    );
  });

  test('本机行的名称 / 版本取 selfInfo', () {
    final List<SrsDeviceView> views = srsDeviceViewsOf(<String, Object?>{
      'selfInfo': <String, Object?>{
        'name': '书房台式机',
        'app': '3.3',
        'platform': 'windows',
      },
      'devices': <Object?>[
        <String, Object?>{'device': 'me', 'self': true},
        <String, Object?>{'device': 'peer', 'name': 'iPhone 17', 'app': '3.3'},
      ],
    });
    expect(
      views.first.displayName(formatTime: (DateTime _) => ''),
      '书房台式机（Fushi 3.3）',
    );
    expect(views.first.platform, 'windows');
    expect(views.last.name, 'iPhone 17');
  });

  test('设备显示名：「名称（Fushi 版本）」/ 对端名 / 未命名 · 最后在线', () {
    String fmt(DateTime t) => '${t.toUtc().year}';
    expect(
      const SrsDeviceView(
        id: 'x',
        name: 'iPhone 17',
        app: '3.3',
      ).displayName(formatTime: fmt),
      'iPhone 17（Fushi 3.3）',
    );
    expect(
      const SrsDeviceView(
        id: 'x',
        hint: 'Pixel 8',
      ).displayName(formatTime: fmt),
      'Pixel 8',
    );
    expect(
      const SrsDeviceView(
        id: 'x',
        seenAt: 1700000000000,
      ).displayName(formatTime: fmt),
      '未命名设备 · 最后在线 2023',
    );
    expect(const SrsDeviceView(id: 'x').displayName(formatTime: fmt), '未命名设备');
    final SrsDeviceDirectory dir = SrsDeviceDirectory(<SrsDeviceView>[
      const SrsDeviceView(
        id: '0193A1B2-0000-7000-8000-00000000BEEF',
        name: 'Mac',
        app: '3.3',
      ),
    ]);
    expect(
      dir.label(
        '0193a1b200007000800000000000beef#2',
        selfLabel: '本机',
        fallback: '?',
        formatTime: fmt,
      ),
      'Mac（Fushi 3.3）',
    );
    expect(
      dir.label('ffff', selfLabel: '本机', fallback: '?', formatTime: fmt),
      '?',
    );
  });
}
