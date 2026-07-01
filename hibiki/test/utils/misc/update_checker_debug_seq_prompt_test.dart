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

  // TODO-1049：debug 通道改为「单一滚动 GitHub Release」（固定 tag `debug-rolling`），
  // 让 Releases 列表里 debug 永远只有 1 条、不再每次 push 堆一条。发布侧把两件事解耦：
  //   * manifest 的 `tag` 字段仍写版本化 `v<version>-debug.<seq>+<sha>`（客户端据 `<seq>`
  //     判「有无更新」，逻辑零改动）；
  //   * 资产 `browser_download_url` 指向 `releases/download/debug-rolling/<name>`（滚动 tag）。
  // 本组守卫「客户端对下载 URL 里的 tag 段完全无感」这一契约：只要版本化 `tag` 递进就判更新，
  // 且下载 URL 原样透传（不从 URL 反解 tag），滚动 tag 不破坏任何既有行为。
  group('rolling debug release: versioned tag vs debug-rolling download URL '
      '(TODO-1049)', () {
    String rollingManifestJson({
      required String tag,
      required String version,
    }) {
      // 关键：assets 的下载 URL 用固定滚动 tag `debug-rolling`，而 manifest.tag 用
      // 版本化 tag —— 正是 publish_update_manifest.sh 的 DOWNLOAD_TAG 解耦产物。
      return _debugManifestJson(
        tag: tag,
        version: version,
        assets: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'hibiki-$version-abc1234-debug.apk',
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/debug-rolling/hibiki-$version-abc1234-debug.apk',
          },
          <String, dynamic>{
            'name': 'hibiki-$version-windows-setup.exe',
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/debug-rolling/hibiki-$version-windows-setup.exe',
          },
        ],
      );
    }

    test('higher seq still prompts; download URL uses debug-rolling verbatim',
        () async {
      final Map<String, dynamic>? release = buildReleaseFromManifest(
        rollingManifestJson(
          tag: 'v0.11.1-debug.5614+abc1234',
          version: '0.11.1-debug.5614',
        ),
      );
      expect(release, isNotNull);
      // 版本比较仍走版本化 tag（含 seq），与滚动下载 tag 无关。
      expect(release!['tag_name'], 'v0.11.1-debug.5614+abc1234');

      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[release],
        currentVersion: _kInstalled,
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );

      expect(selected, isNotNull, reason: 'seq 5614 > 5613：仍必须判为有更新');
      expect(selected!.version, '0.11.1-debug.5614');
      // 下载 URL 原样透传滚动 tag：客户端不从 URL 反解 tag，滚动 tag 不影响下载。
      expect(
        selected.downloadUrl,
        'https://github.com/hajisensai/hibiki/releases/download/debug-rolling/hibiki-0.11.1-debug.5614-windows-setup.exe',
      );
    });

    test('same seq under a rolling download URL still yields no prompt',
        () async {
      final Map<String, dynamic> release = buildReleaseFromManifest(
        rollingManifestJson(
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
      expect(selected, isNull,
          reason: '同 seq（即便下载 URL 是滚动 tag）也不得判为有更新');
    });
  });
}
