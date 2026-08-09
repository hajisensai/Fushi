/// 图片资产下载器。二进制响应不经过 JSON transport；仍遵守超时、429/5xx
/// Retry-After 与有界退避，并把单图失败交给作品协调器隔离。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';

class VideoMetadataDownloadedAsset {
  const VideoMetadataDownloadedAsset({
    required this.bytes,
    required this.extension,
    this.contentType,
  });

  final Uint8List bytes;
  final String extension;
  final String? contentType;
}

class VideoMetadataAssetDownloader {
  VideoMetadataAssetDownloader({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _sleep = sleep ?? Future<void>.delayed;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxRetryDelay;
  final Future<void> Function(Duration) _sleep;

  Future<VideoMetadataDownloadedAsset> download(String url) async {
    final Uri uri = Uri.parse(url);
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final http.Response response = await _client.get(uri).timeout(timeout);
        final bool retryable =
            response.statusCode == 429 || response.statusCode >= 500;
        if (retryable && attempt < maxAttempts) {
          final Duration requestedDelay = parseRetryAfter(
                response.headers['retry-after'],
                now: DateTime.now(),
              ) ??
              baseBackoff * attempt;
          await _sleep(
            requestedDelay > maxRetryDelay ? maxRetryDelay : requestedDelay,
          );
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw VideoMetadataNetworkException(
            'image download HTTP ${response.statusCode}',
            statusCode: response.statusCode,
          );
        }
        final String? contentType = response.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if (contentType == null ||
            contentType.isEmpty ||
            !contentType.startsWith('image/')) {
          throw VideoMetadataNetworkException(
            'image download returned a non-image Content-Type',
            statusCode: response.statusCode,
          );
        }
        final Uint8List bytes = response.bodyBytes;
        final String? extension = _magicExtension(bytes);
        if (extension == null) {
          throw VideoMetadataNetworkException(
            bytes.isEmpty
                ? 'image download returned an empty body'
                : 'image download failed image signature validation',
            statusCode: response.statusCode,
          );
        }
        return VideoMetadataDownloadedAsset(
          bytes: bytes,
          extension: extension,
          contentType: contentType,
        );
      } on VideoMetadataNetworkException catch (error) {
        lastError = error;
        final int? statusCode = error.statusCode;
        if (attempt >= maxAttempts ||
            (statusCode != null && statusCode != 429 && statusCode < 500)) {
          rethrow;
        }
        await _sleep(baseBackoff * attempt > maxRetryDelay
            ? maxRetryDelay
            : baseBackoff * attempt);
      } on Object catch (error) {
        lastError = error;
        if (attempt >= maxAttempts) rethrow;
        await _sleep(baseBackoff * attempt > maxRetryDelay
            ? maxRetryDelay
            : baseBackoff * attempt);
      }
    }
    if (lastError case final Exception exception) throw exception;
    if (lastError case final Error error) throw error;
    throw VideoMetadataNetworkException(
      'image download failed: ${lastError ?? 'unknown error'}',
    );
  }

  static String? _magicExtension(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return '.jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return '.gif';
    }
    return null;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
