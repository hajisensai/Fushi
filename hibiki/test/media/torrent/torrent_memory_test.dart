import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/torrent_memory.dart';

void main() {
  group('computeTorrentMemorySettings', () {
    test('explicit limit overrides RAM; scales & clamps', () {
      final TorrentMemorySettings s = computeTorrentMemorySettings(
        memoryLimitMb: 256,
        totalRamMb: 16000,
      );
      // 256MB 预算：connections=512(256*2), 夹在[50,800]内。
      expect(s.connectionsLimit, 512);
      // 磁盘缓冲 = 256/4=64MB。
      expect(s.maxQueuedDiskBytes, 64 * 1024 * 1024);
      // peer 列表 256*20=5120 → 夹到 4000。
      expect(s.maxPeerlistSize, 4000);
      // 发送缓冲 256*8*1024=2MB，在[512K,4M]内。
      expect(s.sendBufferWatermark, 256 * 8 * 1024);
    });

    test('auto budget ~1/8 RAM, clamped [128,2048]', () {
      // 8GB → 1024MB 预算 → connections 夹到 800(2048>800)。
      final TorrentMemorySettings big = computeTorrentMemorySettings(
        memoryLimitMb: 0,
        totalRamMb: 8192,
      );
      expect(big.connectionsLimit, 800);
      expect(big.maxQueuedDiskBytes, 256 * 1024 * 1024); // 1024/4=256 上限

      // 512MB 机器 → 1/8=64 → 夹到 128 下限。
      final TorrentMemorySettings small = computeTorrentMemorySettings(
        memoryLimitMb: 0,
        totalRamMb: 512,
      );
      expect(small.connectionsLimit, 256); // 128*2
    });

    test('RAM unknown (0) → conservative 256MB budget', () {
      final TorrentMemorySettings s = computeTorrentMemorySettings(
        memoryLimitMb: 0,
        totalRamMb: 0,
      );
      expect(s.connectionsLimit, 512); // 256*2
    });

    test('tiny explicit limit clamps connections to floor 50', () {
      final TorrentMemorySettings s = computeTorrentMemorySettings(
        memoryLimitMb: 10,
        totalRamMb: 0,
      );
      expect(s.connectionsLimit, 50);
      expect(s.maxQueuedDiskBytes, 4 * 1024 * 1024); // floor 4MB
      expect(s.sendBufferWatermark, 512 * 1024); // floor 512KB
      expect(s.maxPeerlistSize, 500); // floor
    });
  });

  group('parseProcMeminfoMemTotalMb', () {
    test('parses MemTotal kB → MB', () {
      const String meminfo = 'MemTotal:       16305512 kB\n'
          'MemFree:         1234567 kB\n';
      expect(parseProcMeminfoMemTotalMb(meminfo), 16305512 ~/ 1024);
    });

    test('missing MemTotal → null', () {
      expect(parseProcMeminfoMemTotalMb('MemFree: 100 kB'), isNull);
    });

    test('garbage → null', () {
      expect(parseProcMeminfoMemTotalMb('MemTotal: not-a-number'), isNull);
    });
  });
}
