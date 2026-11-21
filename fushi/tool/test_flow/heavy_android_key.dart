// A local Android release build needs fushi/android/key.properties (build.gradle
// refuses to produce a debug-signed release). Machines without the real key --
// most dev machines, every fresh worktree -- had agents make a throwaway
// keystore by hand for each verification and delete it afterwards: the same
// keytool + key.properties steps over and over (user, 2026-11-21: "本机没有
// release 签名 key，每次验证都用一次性 key 是会重复操作啊").
//
// heavy.dart now does it once per machine, as dist_test workers already do
// (tool/dist_test/worker_build.sh): one check keystore under
// ~/.fushi/android-check-key/ (made with keytool on first use, random
// password), copied into a worktree that has no key.properties, with a
// key.properties carrying [kHeavyCheckKeyMarker]. A key.properties without
// that marker is the real key (or someone else's) and is never touched. The
// check key signs builds that only prove "it compiles and packages"; it can
// never update an installed official app (different signature), and releases
// are signed in CI.

import 'dart:io';
import 'dart:math';

/// First line of a key.properties heavy.dart wrote for the check key.
const String kHeavyCheckKeyMarker =
    '# fushi heavy local check key: compile / package checks only, never a release';

/// The keystore file name inside fushi/android/ (git-ignored via `**/*.jks`).
const String kHeavyCheckKeyStore = 'fushi-check.jks';

const String _alias = 'fushi-check';

String _launcherName(String exe) {
  final String last = exe.replaceAll(r'\', '/').split('/').last.toLowerCase();
  return last.replaceFirst(RegExp(r'\.(bat|exe|cmd)$'), '');
}

String _norm(String p, bool isWindows) {
  final String s = p.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
  return isWindows ? s.toLowerCase() : s;
}

/// Whether [command], about to run here from [cwd], may sign an Android
/// release of the app: a `gradlew` inside `<checkout>/fushi/android`, or a
/// `flutter build apk|appbundle` from `<checkout>/fushi` that is not
/// `--debug`. (Debug builds use the debug key; key.properties is harmless for
/// them, but there is no reason to write it.)
bool heavyCommandSignsAndroidRelease(
  List<String> command, {
  required String cwd,
  required String checkout,
  required bool isWindows,
}) {
  if (command.isEmpty) return false;
  final String name = _launcherName(command.first);
  final String here = _norm(cwd, isWindows);
  final String app = _norm('$checkout/fushi', isWindows);
  if (name == 'gradlew') {
    final String android = '$app/android';
    if (!(here == android || here.startsWith('$android/'))) return false;
    return command
        .skip(1)
        .any(
          (String a) =>
              RegExp(r'(release|bundle)', caseSensitive: false).hasMatch(a) &&
              !RegExp(r'debug', caseSensitive: false).hasMatch(a),
        );
  }
  if (name != 'flutter' || here != app) return false;
  final List<String> args = command.skip(1).toList();
  final int build = args.indexOf('build');
  if (build == -1 || build + 1 >= args.length) return false;
  final String target = args[build + 1];
  if (target != 'apk' && target != 'appbundle') return false;
  return !args.contains('--debug') && !args.contains('--config-only');
}

/// Makes sure `<androidDir>/key.properties` can sign a release: leaves a real
/// one alone, otherwise installs the machine's check key (creating it with
/// [keytool] on first use). Returns a one-line note for stderr, or null when
/// nothing needed doing.
///
/// [keytool] runs `keytool` with the given arguments and returns its exit
/// code; [home] is the user's home directory.
Future<String?> heavyEnsureAndroidCheckKey({
  required String androidDir,
  required String home,
  required Future<int> Function(List<String> args) keytool,
}) async {
  final File props = File('$androidDir/key.properties');
  if (props.existsSync() &&
      !props.readAsStringSync().startsWith(kHeavyCheckKeyMarker)) {
    return null; // The real key, or one this machine's owner set up.
  }
  final Directory store = Directory('$home/.fushi/android-check-key');
  final File jks = File('${store.path}/$kHeavyCheckKeyStore');
  final File password = File('${store.path}/password');
  String? note;
  if (!jks.existsSync() || !password.existsSync()) {
    store.createSync(recursive: true);
    if (jks.existsSync()) jks.deleteSync();
    final Random random = Random.secure();
    final String pass = List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final int exit = await keytool(<String>[
      '-genkeypair',
      '-keystore',
      jks.path,
      '-storetype',
      'PKCS12',
      '-storepass',
      pass,
      '-keypass',
      pass,
      '-alias',
      _alias,
      '-keyalg',
      'RSA',
      '-keysize',
      '2048',
      '-validity',
      '36500',
      '-dname',
      'CN=fushi local check key',
    ]);
    if (exit != 0 || !jks.existsSync()) {
      return 'keytool could not make the local Android check key (exit $exit); '
          'a release build will stop at the missing key.properties';
    }
    password.writeAsStringSync(pass);
    note =
        'made the local Android check key in ${store.path} (once per machine)';
  }
  final String pass = password.readAsStringSync().trim();
  final File local = File('$androidDir/$kHeavyCheckKeyStore');
  final List<int> want = jks.readAsBytesSync();
  if (!local.existsSync() || !_same(local.readAsBytesSync(), want)) {
    local.writeAsBytesSync(want);
  }
  final String text =
      '$kHeavyCheckKeyMarker\n'
      'storeFile=$kHeavyCheckKeyStore\n'
      'storePassword=$pass\n'
      'keyAlias=$_alias\n'
      'keyPassword=$pass\n';
  if (!props.existsSync() || props.readAsStringSync() != text) {
    props.writeAsStringSync(text);
    note ??=
        'signing this release build with the local check key '
        '(no real android/key.properties here; never ship it)';
  }
  return note;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The `keytool` to run: JAVA_HOME's, Android Studio's bundled JBR, else the
/// one on PATH (the same order as tool/dist_test/worker_build.sh).
String heavyKeytool({
  required Map<String, String> env,
  required bool isWindows,
  bool Function(String path)? fileExists,
}) {
  final bool Function(String) exists =
      fileExists ?? (String p) => File(p).existsSync();
  final String exe = isWindows ? 'keytool.exe' : 'keytool';
  final String? javaHome = env['JAVA_HOME'];
  final List<String> dirs = <String>[
    if (javaHome != null && javaHome.isNotEmpty) '$javaHome/bin',
    if (isWindows) 'C:/Program Files/Android/Android Studio/jbr/bin',
    if (!isWindows)
      '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin',
    if (env['HOME'] != null) '${env['HOME']}/android-studio/jbr/bin',
  ];
  for (final String d in dirs) {
    if (exists('$d/$exe')) return '$d/$exe';
  }
  return exe;
}
