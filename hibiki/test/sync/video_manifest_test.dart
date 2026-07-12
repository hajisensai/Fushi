import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/video_manifest.dart';

void main() {
  group('RemoteVideoManifest roundtrip', () {
    test('toJson → fromJson preserves every field', () {
      final RemoteVideoManifest manifest = RemoteVideoManifest(
        videos: <RemoteVideoManifestEntry>[
          const RemoteVideoManifestEntry(
            uid: 'video/A',
            title: 'Alpha',
            videoAsset: 'video_A_deadbeef.mkv',
            sizeBytes: 1234,
            importedAtMs: 5000,
            coverAsset: 'video_A_deadbeef.cover.jpg',
          ),
          const RemoteVideoManifestEntry(
            uid: 'video/B',
            title: '',
            videoAsset: 'video_B_cafebabe.mp4',
            sizeBytes: 0,
          ),
        ],
      );

      final RemoteVideoManifest decoded =
          RemoteVideoManifest.fromJson(jsonDecode(manifest.canonicalJson()));

      expect(decoded.version, RemoteVideoManifest.currentVersion);
      expect(decoded.videos.length, 2);
      final RemoteVideoManifestEntry a = decoded.videos
          .firstWhere((RemoteVideoManifestEntry e) => e.uid == 'video/A');
      expect(a.title, 'Alpha');
      expect(a.videoAsset, 'video_A_deadbeef.mkv');
      expect(a.sizeBytes, 1234);
      expect(a.importedAtMs, 5000);
      expect(a.coverAsset, 'video_A_deadbeef.cover.jpg');
      final RemoteVideoManifestEntry b = decoded.videos
          .firstWhere((RemoteVideoManifestEntry e) => e.uid == 'video/B');
      expect(b.title, '');
      expect(b.coverAsset, isNull,
          reason: 'omitted coverAsset decodes to null');
      expect(b.importedAtMs, 0);
    });

    test('canonicalJson is order-independent (sorted by uid)', () {
      const RemoteVideoManifestEntry ea = RemoteVideoManifestEntry(
          uid: 'a', title: 'A', videoAsset: 'a.mp4', sizeBytes: 1);
      const RemoteVideoManifestEntry eb = RemoteVideoManifestEntry(
          uid: 'b', title: 'B', videoAsset: 'b.mp4', sizeBytes: 2);
      final String forward =
          const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[ea, eb])
              .canonicalJson();
      final String reversed =
          const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[eb, ea])
              .canonicalJson();
      expect(forward, reversed,
          reason: 'deterministic sort ⇒ same content yields same bytes');
    });

    test('empty manifest publishes zero videos', () {
      expect(RemoteVideoManifest.empty.videos, isEmpty);
      final RemoteVideoManifest decoded = RemoteVideoManifest.fromJson(
          jsonDecode(RemoteVideoManifest.empty.canonicalJson()));
      expect(decoded.videos, isEmpty);
    });
  });

  group('RemoteVideoManifest.fromJson rejects malformed input', () {
    test('non-object throws', () {
      expect(() => RemoteVideoManifest.fromJson(<int>[1, 2, 3]),
          throwsFormatException);
    });

    test('newer version than supported is rejected (no lossy downgrade)', () {
      expect(
        () => RemoteVideoManifest.fromJson(<String, dynamic>{
          'version': RemoteVideoManifest.currentVersion + 1,
          'videos': <dynamic>[],
        }),
        throwsFormatException,
      );
    });

    test('entry missing required key throws', () {
      expect(
        () => RemoteVideoManifest.fromJson(<String, dynamic>{
          'version': 1,
          'videos': <dynamic>[
            <String, dynamic>{'uid': 'x', 'title': 'X'}, // no videoAsset
          ],
        }),
        throwsFormatException,
      );
    });

    test('bad-typed sizeBytes/importedAtMs degrade to 0, not throw', () {
      final RemoteVideoManifest m =
          RemoteVideoManifest.fromJson(<String, dynamic>{
        'version': 1,
        'videos': <dynamic>[
          <String, dynamic>{
            'uid': 'x',
            'title': 'X',
            'videoAsset': 'x.mp4',
            'sizeBytes': 'not-an-int',
            'importedAtMs': null,
          },
        ],
      });
      expect(m.videos.single.sizeBytes, 0);
      expect(m.videos.single.importedAtMs, 0);
    });
  });

  group('asset name helpers', () {
    test('videoAssetName is deterministic, keeps extension, sanitizes uid', () {
      final String name = videoAssetName('video/安達 2', '/anime/Ada.mkv');
      expect(name, endsWith('.mkv'));
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name), isTrue,
          reason: 'asset name must be filesystem-safe across backends');
      expect(name, videoAssetName('video/安達 2', '/anime/Ada.mkv'),
          reason: 'deterministic');
    });

    test('extensionless video path falls back to .mp4', () {
      expect(videoAssetName('u', '/x/novideoext'), endsWith('.mp4'));
    });

    test('videoCoverAssetName carries .cover marker + cover extension', () {
      final String cover = videoCoverAssetName('video/A', '/covers/a.png');
      expect(cover, contains('.cover'));
      expect(cover, endsWith('.png'));
    });

    test('uids that sanitize to the same base still get distinct asset names',
        () {
      // 'video/1' and 'video_1' both sanitize to 'video_1' — the appended hash
      // of the full uid must keep their asset names distinct (no clobber).
      final String a = videoAssetName('video/1', '/x/a.mp4');
      final String b = videoAssetName('video_1', '/x/b.mp4');
      expect(a, isNot(equals(b)));
    });

    // finding 8：脏扩展名（非 ASCII / 空格 / 多点）不清洗直拼会把非 ASCII 字节送进
    // FTP/SFTP 路径、WebDAV href 而炸；改为「非法即回退 .mp4/.jpg」。
    test(
        'finding8 dirty (non-ASCII) extension falls back, keeps asset name safe',
        () {
      final String v = videoAssetName('u', '/anime/movie.第1話');
      expect(v, endsWith('.mp4'), reason: '.第1話 是脏扩展名，回退 .mp4');
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(v), isTrue,
          reason: '资产名不得含非 ASCII 字节（跨后端路径安全）');

      final String c = videoCoverAssetName('u', '/covers/cover.表紙');
      expect(c, endsWith('.jpg'));
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(c), isTrue);

      // 含空格的脏扩展名也回退。
      expect(videoAssetName('u', '/x/clip.mp4 copy'), endsWith('.mp4'));
      // 合法 ASCII 扩展名保留（含大写）。
      expect(videoAssetName('u', '/x/a.MKV'), endsWith('.MKV'));
    });
  });
}
