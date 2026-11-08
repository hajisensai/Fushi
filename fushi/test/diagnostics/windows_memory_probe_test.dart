import 'dart:io';

import 'package:flutter/painting.dart' show ImageCache;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/diagnostics/windows_memory_probe.dart';

/// #8qHvq2p0oU 等 Windows「停在前台没了」：采样只有工作集 rss / 峰值 max，没有分项。
void main() {
  test('读数排成 priv / sys / commit 三段（MB）', () {
    expect(
      describeWindowsMemory(
        const WindowsMemoryReading(
          privateBytes: 3613 << 20,
          availPhysBytes: 412 << 20,
          totalPhysBytes: 16066 << 20,
          commitUsedBytes: 24000 << 20,
          commitLimitBytes: 25000 << 20,
        ),
      ),
      'priv=3613MB sys=412/16066MB commit=24000/25000MB',
    );
  });

  test('Windows 上真读得到：私有提交非零、可用物理不超过总物理、已提交不超过上限', () {
    final WindowsMemoryReading? r = readWindowsMemory();
    if (!Platform.isWindows) {
      expect(r, isNull);
      expect(windowsMemoryProbe(), isNull);
      return;
    }
    expect(r, isNotNull);
    expect(r!.privateBytes, greaterThan(0));
    expect(r.totalPhysBytes, greaterThan(0));
    expect(r.availPhysBytes, lessThanOrEqualTo(r.totalPhysBytes));
    expect(r.commitUsedBytes, lessThanOrEqualTo(r.commitLimitBytes));
    expect(windowsMemoryProbe(), startsWith('priv='));
  });

  test('解码图缓存读数', () {
    final ImageCache cache = ImageCache()..maximumSizeBytes = 100 << 20;
    expect(describeImageCache(cache), 'img=0/100MB n=0 live=0');
  });
}
