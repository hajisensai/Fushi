import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// TODO-772 症状1 链路自验：用户报「装着 0.11.1-debug.5613 但没收到更新提示」。
/// 本测试把 latest-debug.json 形态的 manifest 喂进既有选择链
/// （buildReleaseFromManifest → selectUpdateReleaseForCurrentPlatform），
/// 证明「当 manifest 序号高于本机时，链路确会解析出非空 selection 且版本更新」，
/// 以及「本机已是最新（同序号）时正确不弹」。
/// 这把症状1 的真伪收窄到纯数据 / 网络侧（manifest 是否发布、能否拉到），
/// 发布侧定位是另案遗留。
String _debugManifestJson({
  required String tag,
  required String version,
  List<Map<String, dynamic>>? assets,
}) {
  return jsonEncode(<String, dynamic>{
    'schemaVersion': kUpdateManifestSchemaVersion,
    'version': version,
    'tag': tag,
    'channel': 'debug',
    'prerelease': true,
    'notes': 'debug build $version',
    'assets': assets ??
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'hibiki-$version-abc1234-debug.apk',
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/$tag/hibiki-$version-abc1234-debug.apk',
          },
          <String, dynamic>{
            'name': 'hibiki-$version-windows-setup.exe',
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/$tag/hibiki-$version-windows-setup.exe',
          },
        ],
  });
}

const String _kInstalled = '0.11.1-debug.5613';

void main() {
  group('debug update-prompt chain (manifest -> selection)', () {
    test('higher manifest seq (5614 > installed 5613) yields a newer selection',
        () async {
      final Map<String, dynamic>? release = buildReleaseFromManifest(
        _debugManifestJson(
          tag: 'v0.11.1-debug.5614+abc1234',
          version: '0.11.1-debug.5614',
        ),
      );
      expect(release, isNotNull,
          reason: 'a well-formed debug manifest must rebuild into a release');
      expect(release!['tag_name'], 'v0.11.1-debug.5614+abc1234');

      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[release],
        currentVersion: _kInstalled,
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );

      expect(selected, isNotNull, reason: '有更新时链路必须返回非空 selection（即会提示）');
      expect(selected!.version, '0.11.1-debug.5614');
      expect(
        selected.downloadUrl,
        'https://github.com/hajisensai/hibiki/releases/download/v0.11.1-debug.5614+abc1234/hibiki-0.11.1-debug.5614-windows-setup.exe',
      );
    });

    test('isUpdateVersionNewer: 5614 over installed 5613 is newer', () {
      expect(
        isUpdateVersionNewer(
          '0.11.1-debug.5614',
          _kInstalled,
          UpdateChannel.debug,
        ),
        isTrue,
      );
    });

    test('same seq (manifest 5613 == installed 5613) is NOT newer -> no prompt',
        () async {
      expect(
        isUpdateVersionNewer(
          '0.11.1-debug.5613',
          _kInstalled,
          UpdateChannel.debug,
        ),
        isFalse,
        reason: '本机已是最新时不得判定为有更新',
      );

      // 即便 manifest 也是同序号 5613，选择链也不得产出 selection。
      final Map<String, dynamic> release = buildReleaseFromManifest(
        _debugManifestJson(
          tag: 'v0.11.1-debug.5613+abc1234',
          version: '0.11.1-debug.5613',
        ),
      )!;
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[release],
        currentVersion: _kInstalled,
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );
      expect(selected, isNull, reason: '同序号时链路不得返回 selection（即不弹）');
    });
  });
}
