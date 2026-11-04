import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/platform/widget_progress.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate;
import 'package:fushi/src/utils/net/app_http_image.dart'
    show AppImageCacheManager;

/// Longest edge of a widget cover file, in pixels.
const int kWidgetCoverMaxEdge = 512;

/// Server covers for the On deck widget as local files under
/// `<appSupport>/widget_covers/` (Glance can only draw local bitmaps).
///
/// - Authenticated media-server covers go through the browser's own
///   [ServerContinueCandidate.coverFetcher] (same path the dashboard uses);
///   plain URLs go through the shared image disk cache.
/// - Every file is downscaled to [kWidgetCoverMaxEdge] and written once; a file
///   that already exists is reused without any network.
/// - [resolve] is time-boxed: items whose cover is not ready in time get '' (the
///   widget draws a glyph) and the download keeps running, so the next publish
///   picks the finished file up. A slow server never blocks a publish.
class WidgetCoverCache {
  WidgetCoverCache({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;
  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};

  Future<Directory> _directory() async {
    final Directory dir =
        _directoryOverride ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'widget_covers',
          ),
        );
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Local cover path per candidate key ([ServerContinueCandidate.key]); a
  /// missing entry means "no cover (yet)". Also prunes files no candidate uses.
  Future<Map<String, String>> resolve(
    List<ServerContinueCandidate> candidates, {
    Duration timeBox = const Duration(seconds: 5),
  }) async {
    final Map<String, String> out = <String, String>{};
    try {
      final Directory dir = await _directory();
      final Set<String> keep = <String>{};
      final List<Future<void>> jobs = <Future<void>>[];
      for (final ServerContinueCandidate c in candidates) {
        final String? url = c.coverUrl;
        if (url == null || url.isEmpty) continue;
        final String name = widgetCoverFileName(c.coverCacheKey ?? url);
        keep.add(name);
        final File file = File(p.join(dir.path, name));
        if (file.existsSync() && file.lengthSync() > 0) {
          out[c.key] = file.path;
          continue;
        }
        jobs.add(
          _ensure(c, file).timeout(timeBox, onTimeout: () => null).then((
            String? path,
          ) {
            if (path != null) out[c.key] = path;
          }),
        );
      }
      await Future.wait(jobs);
      await _prune(dir, keep);
    } on Object catch (error) {
      debugPrint('WidgetCoverCache: resolve failed: $error');
    }
    return out;
  }

  Future<String?> _ensure(ServerContinueCandidate c, File file) {
    return _inflight.putIfAbsent(file.path, () async {
      try {
        final Uint8List raw = await _fetch(c);
        final Uint8List png = await _downscale(raw);
        final File tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(png, flush: true);
        await tmp.rename(file.path);
        return file.path;
      } on Object catch (error) {
        debugPrint('WidgetCoverCache: cover failed (${c.key}): $error');
        return null;
      } finally {
        unawaited(_inflight.remove(file.path));
      }
    });
  }

  Future<Uint8List> _fetch(ServerContinueCandidate c) async {
    final String url = c.coverUrl!;
    final fetcher = c.coverFetcher;
    if (fetcher != null) return fetcher.fetchRemoteCover(url);
    final File cached = await AppImageCacheManager().getSingleFile(
      url,
      key: c.coverCacheKey,
    );
    return cached.readAsBytes();
  }

  /// Decodes, shrinks so the longest edge is at most [kWidgetCoverMaxEdge]
  /// (never upscales) and re-encodes as PNG.
  static Future<Uint8List> _downscale(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    try {
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      try {
        final int w = descriptor.width;
        final int h = descriptor.height;
        if (w <= 0 || h <= 0) throw const FormatException('empty image');
        final double scale = kWidgetCoverMaxEdge / (w > h ? w : h);
        final ui.Codec codec = await descriptor.instantiateCodec(
          targetWidth: scale < 1 ? (w * scale).round().clamp(1, w) : w,
          targetHeight: scale < 1 ? (h * scale).round().clamp(1, h) : h,
        );
        try {
          final ui.FrameInfo frame = await codec.getNextFrame();
          final ByteData? png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          frame.image.dispose();
          if (png == null) throw const FormatException('png encode failed');
          return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<void> _prune(Directory dir, Set<String> keep) async {
    final List<String> existing = <String>[
      for (final FileSystemEntity e in dir.listSync())
        if (e is File) p.basename(e.path),
    ];
    for (final String name in widgetCoversToPrune(
      existing: existing,
      keep: keep,
    )) {
      // Leave in-flight temp files of a concurrent download alone.
      if (name.endsWith('.tmp')) continue;
      try {
        await File(p.join(dir.path, name)).delete();
      } on Object {
        // Best effort; the next publish prunes again.
      }
    }
  }
}
