import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/updates/usage_heartbeat_device.dart';

void main() {
  test('架构名归一：Android ABI / Windows 环境变量 / uname 三种写法', () {
    expect(normalizeHeartbeatArch('arm64-v8a'), 'arm64');
    expect(normalizeHeartbeatArch('aarch64'), 'arm64');
    expect(normalizeHeartbeatArch('armeabi-v7a'), 'arm');
    expect(normalizeHeartbeatArch('x86_64'), 'x64');
    expect(normalizeHeartbeatArch('AMD64'), 'x64');
    expect(normalizeHeartbeatArch('x86'), 'x86');
    expect(normalizeHeartbeatArch('riscv64'), 'riscv64');
    expect(normalizeHeartbeatArch('loongarch-64'), 'loongarch_64');
    expect(normalizeHeartbeatArch('weird arch!'), isNull);
    expect(normalizeHeartbeatArch(null), isNull);
  });

  test('Windows 宿主架构：ARM64 上模拟跑的 x64 进程仍报 arm64', () {
    expect(
      windowsHostArch(<String, String>{
        'PROCESSOR_ARCHITECTURE': 'AMD64',
        'PROCESSOR_IDENTIFIER': 'ARMv8 (64-bit) Family 8 Model D4B Revision 0',
      }),
      'arm64',
    );
    expect(
      windowsHostArch(<String, String>{
        'PROCESSOR_ARCHITECTURE': 'AMD64',
        'PROCESSOR_IDENTIFIER': 'AMD64 Family 25 Model 97 Stepping 2',
      }),
      'x64',
    );
    expect(
      windowsHostArch(<String, String>{
        'PROCESSOR_ARCHITECTURE': 'x86',
        'PROCESSOR_ARCHITEW6432': 'AMD64',
        'PROCESSOR_IDENTIFIER': 'Intel64 Family 6 Model 183',
      }),
      'x64',
    );
    expect(windowsHostArch(<String, String>{}), isNull);
  });

  test('dart:ffi Abi → 架构记号', () {
    expect(abiHeartbeatArch(Abi.linuxX64), 'x64');
    expect(abiHeartbeatArch(Abi.linuxArm64), 'arm64');
    expect(abiHeartbeatArch(Abi.windowsIA32), 'x86');
  });

  test('系统大版本：Windows 按 22000 分 10 / 11；Linux 取 id-版本', () {
    expect(windowsMajorVersion(19045), '10');
    expect(windowsMajorVersion(22000), '11');
    expect(windowsMajorVersion(26200), '11');
    expect(linuxOsVersion('ubuntu', '24.04'), 'ubuntu-24.04');
    expect(linuxOsVersion('arch', null), 'arch');
    expect(linuxOsVersion('Fedora Linux', '41'), 'fedoralinux-41');
    expect(linuxOsVersion(null, '1'), isNull);
    expect(linuxOsVersion('a' * 40, '1')!.length, 32);
  });

  test('Android 安装来源只报类别，不报包名', () {
    const String own = 'app.fushi.reader';
    expect(classifyAndroidInstallSource(null, own), 'adb');
    expect(classifyAndroidInstallSource('', own), 'adb');
    expect(classifyAndroidInstallSource('com.android.vending', own), 'play');
    expect(classifyAndroidInstallSource('org.fdroid.fdroid', own), 'fdroid');
    expect(classifyAndroidInstallSource('com.looker.droidify', own), 'fdroid');
    expect(
      classifyAndroidInstallSource('dev.imranr.obtainium.fdroid', own),
      'obtainium',
    );
    expect(classifyAndroidInstallSource(own, own), 'self_update');
    expect(
      classifyAndroidInstallSource('com.google.android.packageinstaller', own),
      'manual',
    );
    expect(
      classifyAndroidInstallSource('com.mi.android.globalFileexplorer', own),
      'manual',
    );
  });

  test('Windows 安装来源按 exe 旁有没有 Inno 卸载器', () {
    expect(classifyWindowsInstallSource(hasUninstaller: true), 'installer');
    expect(classifyWindowsInstallSource(hasUninstaller: false), 'portable');
  });

  test('输出全部落在服务端的形状校验里', () {
    final RegExp arch = RegExp(r'^[a-z0-9_]{1,16}$');
    final RegExp os = RegExp(r'^[A-Za-z0-9._-]{1,32}$');
    final RegExp source = RegExp(r'^[a-z_]{1,24}$');
    for (final String raw in <String>['arm64-v8a', 'AMD64', 'loongarch-64']) {
      expect(arch.hasMatch(normalizeHeartbeatArch(raw)!), isTrue, reason: raw);
    }
    for (final String v in <String>[
      windowsMajorVersion(19045),
      linuxOsVersion('Fedora Linux', '41')!,
      linuxOsVersion('a' * 40, '1')!,
    ]) {
      expect(os.hasMatch(v), isTrue, reason: v);
    }
    for (final String? installer in <String?>[
      null,
      'com.android.vending',
      'org.fdroid.fdroid',
      'dev.imranr.obtainium',
      'x',
    ]) {
      expect(
        source.hasMatch(classifyAndroidInstallSource(installer, 'x')),
        isTrue,
      );
    }
  });
}
