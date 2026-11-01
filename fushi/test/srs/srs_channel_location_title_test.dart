import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/utils.dart';

/// 同步与历史页「存储位置」的通道标题：位置 ID 不能原样露给用户（互联位置的 ID 是 host 设备 ID，
/// 一长串 base64，用户截图里看着像乱码）。
void main() {
  const String hostId = 'pzzCeD9XhMUjc8aHC58YYX__FAOfI8wmmSA-Azn_Ctg=';

  test('互联位置：本机就是 host 时写「本机」，不显示 host 设备 ID', () {
    final String title = srsChannelLocationTitle(
      'interconnect:$hostId',
      ownDeviceId: hostId,
    );
    expect(
      title,
      '${t.sync_backend_fushi_server} · ${t.srs_timeline_this_device}',
    );
    expect(title, isNot(contains(hostId)));
  });

  test('互联位置：连别的 host 时用配对记下的 host 名', () {
    expect(
      srsChannelLocationTitle(
        'interconnect:$hostId',
        ownDeviceId: 'other',
        hostNames: <String, String>{hostId: '  书房电脑 '},
      ),
      '${t.sync_backend_fushi_server} · 书房电脑',
    );
  });

  test('互联位置：没有名字时退到前 8 位', () {
    expect(
      srsChannelLocationTitle('interconnect:$hostId'),
      '${t.sync_backend_fushi_server} · pzzCeD9X',
    );
  });

  test('云盘位置（含防扫盘混淆前缀）：后端名 · 账户', () {
    expect(
      srsChannelLocationTitle('obfuscated:googleDrive:a@example.com'),
      '${t.sync_backend_google_drive} · a@example.com',
    );
    expect(
      srsChannelLocationTitle('oneDrive:a@example.com'),
      '${t.sync_backend_onedrive} · a@example.com',
    );
  });

  test('服务器位置：用户@地址，用户为空只给地址', () {
    expect(
      srsChannelLocationTitle('webDav:https://dav.example.com|me'),
      '${t.sync_backend_webdav} · me@https://dav.example.com',
    );
    expect(
      srsChannelLocationTitle('sftp:nas.local:22|'),
      '${t.sync_backend_sftp} · nas.local:22',
    );
  });

  test('认不出的种类：去掉种类前缀原样显示', () {
    expect(srsChannelLocationTitle('store:FakeBackend'), 'FakeBackend');
    expect(srsChannelLocationTitle('plain'), 'plain');
  });
}
