// 反馈 p8vt5jHJgC：Windows 配置完重启后启动失败，
// `FormatException: Unexpected character (at character 1)` + 一长串方框（NUL）。
// 官方桌面插件原地写偏好文件、读时不接异常；断电留下的 NUL 文件让每次
// SharedPreferences.getInstance() 都抛错。换成的存储必须：坏文件不抛、隔离留证、
// 用备份恢复，并且写盘原子。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/durable_shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late Directory dir;
  late SharedPreferencesStorePlatform original;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_durable_prefs_');
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    DurableFileSharedPreferencesStore.drainRecoveryReports();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = original;
    SharedPreferences.resetStatic();
    dir.deleteSync(recursive: true);
  });

  File prefsFile() => File(p.join(dir.path, kSharedPreferencesFileName));

  Future<SharedPreferences> open() async {
    SharedPreferencesStorePlatform.instance =
        DurableFileSharedPreferencesStore.at(
          prefsFile(),
          clock: () => DateTime(2026, 11, 1, 17, 5),
        );
    SharedPreferences.resetStatic();
    return SharedPreferences.getInstance();
  }

  List<String> quarantined() => dir
      .listSync()
      .map((FileSystemEntity e) => p.basename(e.path))
      .where((String n) => n.contains(kSharedPreferencesCorruptSuffix))
      .toList();

  test('沿用官方插件写下的存量文件，类型保真', () async {
    prefsFile().writeAsStringSync(
      jsonEncode(<String, Object>{
        'flutter.data_root': r'E:\Fushi',
        'flutter.flag': true,
        'flutter.n': 3,
        'flutter.list': <String>['a', 'b'],
      }),
    );
    final SharedPreferences prefs = await open();
    expect(prefs.getString('data_root'), r'E:\Fushi');
    expect(prefs.getBool('flag'), isTrue);
    expect(prefs.getInt('n'), 3);
    expect(prefs.getStringList('list'), <String>['a', 'b']);
  });

  test('NUL 填满的坏文件：不抛，隔离留证，用上次的备份恢复', () async {
    prefsFile().writeAsStringSync(
      jsonEncode(<String, Object>{'flutter.data_root': r'E:\Fushi'}),
    );
    // 第一次正常启动：读通过，留下备份。
    await open();
    expect(
      File('${prefsFile().path}$kSharedPreferencesBackupSuffix').existsSync(),
      isTrue,
    );

    // 写到一半断电：长度不变、内容全是 NUL。
    prefsFile().writeAsBytesSync(List<int>.filled(64, 0));

    final SharedPreferences prefs = await open();
    expect(prefs.getString('data_root'), r'E:\Fushi');
    expect(quarantined(), hasLength(1));
    // 主文件已重写成合法 JSON。
    expect(
      (jsonDecode(prefsFile().readAsStringSync()) as Map)['flutter.data_root'],
      r'E:\Fushi',
    );
    final List<String> reports =
        DurableFileSharedPreferencesStore.drainRecoveryReports();
    expect(reports.single, contains('备份恢复'));
  });

  test('坏文件且没有备份：以空偏好继续启动，坏文件原样隔离', () async {
    final List<int> garbage = <int>[0xEF, 0xBB, 0xBF, 0, 0, 0xFF, 0xFE];
    prefsFile().writeAsBytesSync(garbage);

    final SharedPreferences prefs = await open();
    expect(prefs.getKeys(), isEmpty);
    expect(prefsFile().existsSync(), isFalse);
    final List<String> q = quarantined();
    expect(q, hasLength(1));
    expect(File(p.join(dir.path, q.single)).readAsBytesSync(), garbage);
    expect(
      DurableFileSharedPreferencesStore.drainRecoveryReports().single,
      contains('没有可用备份'),
    );

    // 之后照常可写。
    await prefs.setString('k', 'v');
    expect((await open()).getString('k'), 'v');
  });

  test('写盘走临时文件 + rename：不留 .tmp，结果是完整 JSON', () async {
    final SharedPreferences prefs = await open();
    await prefs.setString('data_root', r'D:\Data');
    expect(File('${prefsFile().path}.tmp').existsSync(), isFalse);
    expect(
      (jsonDecode(prefsFile().readAsStringSync()) as Map)['flutter.data_root'],
      r'D:\Data',
    );
  });

  test('只在 Windows / Linux 装；已装过不重复替换', () {
    SharedPreferencesStorePlatform.instance = original;
    expect(
      installDurableDesktopSharedPreferences(isWindowsOrLinux: false),
      isFalse,
    );
    expect(
      installDurableDesktopSharedPreferences(isWindowsOrLinux: true),
      isTrue,
    );
    final SharedPreferencesStorePlatform installed =
        SharedPreferencesStorePlatform.instance;
    expect(installed, isA<DurableFileSharedPreferencesStore>());
    expect(
      installDurableDesktopSharedPreferences(isWindowsOrLinux: true),
      isTrue,
    );
    expect(
      identical(SharedPreferencesStorePlatform.instance, installed),
      isTrue,
    );
  });
}
