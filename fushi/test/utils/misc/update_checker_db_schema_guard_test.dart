import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart' show kFushiDbSchemaVersion;

// 更新器绝不能把用户推到「带的用户库 schema 比本机低」的包：装上后用户库比程序新，
// app 拒绝打开（FushiDatabaseDowngradeException）。CI 在清单每个 asset 上写
// `dbSchemaVersion`，选包时比本机低的一律跳过——不管发布序号 / 基版本怎么判。
// 典型场景：调试版用户已迁到新 schema，正式版从更早的提交构建；或者正式版清单
// 读不到序号、退回基版本比较时高基版本被当成更新。

Map<String, dynamic> _asset(
  String name,
  String version, {
  int? dbSchema,
}) => <String, dynamic>{
  'name': name,
  'browser_download_url':
      'https://github.com/hajisensai/fushi/releases/download/v$version/$name',
  'version': version,
  if (dbSchema != null) 'dbSchemaVersion': dbSchema,
};

String _manifest({
  required String version,
  required String channel,
  required int seq,
  required List<Map<String, dynamic>> assets,
}) => jsonEncode(<String, dynamic>{
  'schemaVersion': kUpdateManifestSchemaVersion,
  'version': version,
  'tag': 'v$version',
  'channel': channel,
  'prerelease': channel != 'formal',
  'releaseSequence': seq,
  'notes': '',
  'assets': assets,
});

Future<UpdateReleaseSelection?> _select(
  String body, {
  required String currentVersion,
  required UpdateChannel channel,
  required int localDbSchema,
  int? currentReleaseSeq,
}) {
  final Map<String, dynamic> release = buildReleaseFromManifest(body)!;
  return selectUpdateReleaseForCurrentPlatform(
    <Map<String, dynamic>>[release],
    currentVersion: currentVersion,
    currentReleaseSeq: currentReleaseSeq,
    channel: channel,
    updater: WindowsUpdater(),
    localDbSchemaVersion: localDbSchema,
  );
}

void main() {
  test('buildReleaseFromManifest 透传 per-asset dbSchemaVersion', () {
    final Map<String, dynamic> release = buildReleaseFromManifest(
      _manifest(
        version: '3.4.0',
        channel: 'formal',
        seq: 27600,
        assets: <Map<String, dynamic>>[
          _asset('fushi-3.4.0-windows-setup.exe', '3.4.0', dbSchema: 154),
        ],
      ),
    )!;
    final Map<String, dynamic> asset = (release['assets'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .single;
    expect(asset['dbSchemaVersion'], 154);
    expect(UpdateAsset.fromReleaseAsset(asset).dbSchemaVersion, 154);
  });

  test('非正整数的 dbSchemaVersion 当作没有', () {
    expect(
      UpdateAsset.fromReleaseAsset(<String, dynamic>{
        'name': 'x',
        'browser_download_url': 'y',
        'dbSchemaVersion': 0,
      }).dbSchemaVersion,
      isNull,
    );
    expect(
      UpdateAsset.fromReleaseAsset(<String, dynamic>{
        'name': 'x',
        'browser_download_url': 'y',
        'dbSchemaVersion': '154',
      }).dbSchemaVersion,
      isNull,
    );
  });

  test('调试版用户：序号更新但 schema 更低的正式版不推', () async {
    final UpdateReleaseSelection? selected = await _select(
      _manifest(
        version: '3.4.0',
        channel: 'formal',
        seq: 27600,
        assets: <Map<String, dynamic>>[
          _asset('fushi-3.4.0-windows-setup.exe', '3.4.0', dbSchema: 154),
        ],
      ),
      currentVersion: '3.4.0-debug.27550',
      channel: UpdateChannel.debug,
      localDbSchema: 155,
    );
    expect(selected, isNull);
  });

  test('序号未知、退回基版本比较时，高基版本但 schema 更低也不推', () async {
    final Map<String, dynamic> release = buildReleaseFromManifest(
      _manifest(
        version: '3.5.0',
        channel: 'formal',
        seq: 1,
        assets: <Map<String, dynamic>>[
          _asset('fushi-3.5.0-windows-setup.exe', '3.5.0', dbSchema: 150),
        ],
      ),
    )!..remove('releaseSequence');
    final UpdateReleaseSelection? selected =
        await selectUpdateReleaseForCurrentPlatform(
          <Map<String, dynamic>>[release],
          currentVersion: '3.4.0',
          channel: UpdateChannel.stable,
          updater: WindowsUpdater(),
          localDbSchemaVersion: 154,
        );
    expect(selected, isNull);
  });

  test('schema 相同或更高照常推', () async {
    for (final int remote in <int>[154, 156]) {
      final UpdateReleaseSelection? selected = await _select(
        _manifest(
          version: '3.4.0',
          channel: 'formal',
          seq: 27600,
          assets: <Map<String, dynamic>>[
            _asset('fushi-3.4.0-windows-setup.exe', '3.4.0', dbSchema: remote),
          ],
        ),
        currentVersion: '3.4.0-debug.27550',
        channel: UpdateChannel.debug,
        localDbSchema: 154,
      );
      expect(selected, isNotNull, reason: 'remote schema $remote');
      expect(selected!.asset!.dbSchemaVersion, remote);
    }
  });

  test('旧清单没有 dbSchemaVersion：只按发布序号判（不卡住更新）', () async {
    final UpdateReleaseSelection? selected = await _select(
      _manifest(
        version: '3.4.0',
        channel: 'formal',
        seq: 27600,
        assets: <Map<String, dynamic>>[
          _asset('fushi-3.4.0-windows-setup.exe', '3.4.0'),
        ],
      ),
      currentVersion: '3.4.0-debug.27550',
      channel: UpdateChannel.debug,
      localDbSchema: 155,
    );
    expect(selected, isNotNull);
  });

  test('CI 抠 schema 的正则对得上唯一来源文件', () {
    // tool/publish_update_manifest.sh 用 sed 匹配 `^const int kFushiDbSchemaVersion = N;`，
    // 改写法（换成 getter、加类型修饰、拆行）会让 CI 读不到、发布红；这里先咬住。
    final File source = File(
      '../packages/fushi_core/lib/src/database/db_schema_version.dart',
    );
    final RegExp line = RegExp(
      r'^const int kFushiDbSchemaVersion = ([0-9]+);',
      multiLine: true,
    );
    final List<RegExpMatch> matches = line
        .allMatches(source.readAsStringSync())
        .toList();
    expect(matches, hasLength(1));
    expect(int.parse(matches.single.group(1)!), kFushiDbSchemaVersion);

    // 迁移 PR 若照老习惯把 getter 改回字面量（或合并冲突时取了对方的 `=> N`），清单里的
    // schema 就和库真实版本脱钩；getter 必须只读这个常量。
    final String database = File(
      '../packages/fushi_core/lib/src/database/database.dart',
    ).readAsStringSync();
    expect(
      database,
      contains('int get schemaVersion => kFushiDbSchemaVersion;'),
    );

    final String script = File(
      '../tool/publish_update_manifest.sh',
    ).readAsStringSync();
    expect(
      script,
      contains(
        r's/^const int kFushiDbSchemaVersion = \([0-9][0-9]*\);.*$/\1/p',
      ),
    );
    expect(script, contains('"dbSchemaVersion": db_schema'));
  });
}
