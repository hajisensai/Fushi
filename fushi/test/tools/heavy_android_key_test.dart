import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_android_key.dart';

/// heavy.dart 在本机编 Android release 前自动备一把本机复用的检查 key：
/// 以前每次验证都要代理手工造一次性 keystore、写 key.properties、用完再删。
void main() {
  group('heavyCommandSignsAndroidRelease', () {
    bool signs(List<String> cmd, String cwd) => heavyCommandSignsAndroidRelease(
      cmd,
      cwd: cwd,
      checkout: r'D:\wt',
      isWindows: true,
    );

    test('app 的 release gradle / flutter build 要签名', () {
      expect(
        signs(<String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
        ], r'D:\wt\fushi\android'),
        true,
      );
      expect(
        signs(<String>['./gradlew', 'bundleRelease'], r'D:\WT\Fushi\android'),
        true,
      );
      expect(
        signs(<String>[
          r'D:\sdk\flutter.bat',
          'build',
          'apk',
          '--split-per-abi',
        ], r'D:\wt\fushi'),
        true,
      );
      expect(
        signs(<String>[
          'flutter',
          'build',
          'appbundle',
          '--release',
        ], r'D:\wt\fushi'),
        true,
      );
    });

    test('debug、config-only、别的目录或别的命令不碰', () {
      expect(
        signs(<String>[
          r'.\gradlew.bat',
          ':app:assembleDebug',
        ], r'D:\wt\fushi\android'),
        false,
      );
      expect(
        signs(<String>[
          r'.\gradlew.bat',
          ':app:bundleDebug',
        ], r'D:\wt\fushi\android'),
        false,
      );
      expect(
        signs(<String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
        ], r'D:\other\fushi\android'),
        false,
      );
      expect(
        signs(<String>['flutter', 'build', 'apk', '--debug'], r'D:\wt\fushi'),
        false,
      );
      expect(
        signs(<String>[
          'flutter',
          'build',
          'apk',
          '--config-only',
        ], r'D:\wt\fushi'),
        false,
      );
      expect(
        signs(<String>['flutter', 'build', 'windows'], r'D:\wt\fushi'),
        false,
      );
      expect(signs(<String>['flutter', 'test'], r'D:\wt\fushi'), false);
      expect(signs(<String>[], r'D:\wt\fushi'), false);
    });
  });

  group('heavyEnsureAndroidCheckKey', () {
    late Directory tmp;
    late String android;
    late String home;
    late int keytoolRuns;

    Future<int> fakeKeytool(List<String> args) async {
      keytoolRuns++;
      final String jks = args[args.indexOf('-keystore') + 1];
      File(jks).writeAsBytesSync(<int>[1, 2, 3, keytoolRuns]);
      return 0;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('heavy_key_');
      android = '${tmp.path}/fushi/android';
      home = '${tmp.path}/home';
      Directory(android).createSync(recursive: true);
      keytoolRuns = 0;
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('首次在本机生成一次，之后各 worktree 复用同一把', () async {
      final String? first = await heavyEnsureAndroidCheckKey(
        androidDir: android,
        home: home,
        keytool: fakeKeytool,
      );
      expect(first, contains('once per machine'));
      final String props = File('$android/key.properties').readAsStringSync();
      expect(props, startsWith(kHeavyCheckKeyMarker));
      expect(props, contains('storeFile=$kHeavyCheckKeyStore'));
      expect(File('$android/$kHeavyCheckKeyStore').readAsBytesSync(), <int>[
        1,
        2,
        3,
        1,
      ]);

      // 另一个 worktree：不再跑 keytool，拷同一把 key。
      final String other = '${tmp.path}/wt2/fushi/android';
      Directory(other).createSync(recursive: true);
      final String? second = await heavyEnsureAndroidCheckKey(
        androidDir: other,
        home: home,
        keytool: fakeKeytool,
      );
      expect(keytoolRuns, 1);
      expect(second, contains('local check key'));
      expect(File('$other/key.properties').readAsStringSync(), props);
      expect(File('$other/$kHeavyCheckKeyStore').readAsBytesSync(), <int>[
        1,
        2,
        3,
        1,
      ]);

      // 已备好的 worktree 再跑一次：什么都不做。
      expect(
        await heavyEnsureAndroidCheckKey(
          androidDir: other,
          home: home,
          keytool: fakeKeytool,
        ),
        isNull,
      );
    });

    test('真 key（无标记的 key.properties）一律不碰', () async {
      const String real =
          'storeFile=release.jks\nstorePassword=x\nkeyAlias=a\nkeyPassword=x\n';
      File('$android/key.properties').writeAsStringSync(real);
      expect(
        await heavyEnsureAndroidCheckKey(
          androidDir: android,
          home: home,
          keytool: fakeKeytool,
        ),
        isNull,
      );
      expect(File('$android/key.properties').readAsStringSync(), real);
      expect(keytoolRuns, 0);
      expect(File('$android/$kHeavyCheckKeyStore').existsSync(), false);
    });

    test('keytool 失败时说明原因、不写 key.properties', () async {
      final String? note = await heavyEnsureAndroidCheckKey(
        androidDir: android,
        home: home,
        keytool: (List<String> _) async => 1,
      );
      expect(note, contains('keytool could not'));
      expect(File('$android/key.properties').existsSync(), false);
    });

    test('heavyKeytool 先找 JAVA_HOME，再找 Android Studio 的 JBR，最后 PATH', () {
      expect(
        heavyKeytool(
          env: <String, String>{'JAVA_HOME': 'C:/jdk'},
          isWindows: true,
          fileExists: (String p) => p == 'C:/jdk/bin/keytool.exe',
        ),
        'C:/jdk/bin/keytool.exe',
      );
      expect(
        heavyKeytool(
          env: <String, String>{},
          isWindows: true,
          fileExists: (String p) => p.contains('Android Studio/jbr'),
        ),
        'C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe',
      );
      expect(
        heavyKeytool(
          env: <String, String>{},
          isWindows: true,
          fileExists: (_) => false,
        ),
        'keytool.exe',
      );
    });
  });
}
