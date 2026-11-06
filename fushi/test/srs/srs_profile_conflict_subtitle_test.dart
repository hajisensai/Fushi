import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart' show SrsRemoteProfile;

/// 反馈 dOv8AdJ6yV：「复习同步冲突」候选只显示「Default · 01a13df1」，用户看不出是哪台设备、
/// 有多少数据，没法选。候选副标题要带上说明文件里报的设备名与笔记数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('有设备名与笔记数：都显示，uid 前缀留着区分同名', () {
    const SrsRemoteProfile c = SrsRemoteProfile(
      uid: '01a13df1-aaaa-bbbb',
      writers: <String>['x'],
      names: <String>{'Default'},
      devices: <String>['Boox Note Air', 'Windows PC'],
      noteCount: 1234,
    );
    expect(
      srsProfileCandidateSubtitle(c),
      'From Boox Note Air, Windows PC · 1234 notes · 01a13df1',
    );
  });

  test('旧版本没报设备名 / 笔记数：只剩 uid 前缀，不编造', () {
    const SrsRemoteProfile c = SrsRemoteProfile(
      uid: '01a13df1-aaaa-bbbb',
      writers: <String>['x'],
    );
    expect(srsProfileCandidateSubtitle(c), '01a13df1');
  });
}
