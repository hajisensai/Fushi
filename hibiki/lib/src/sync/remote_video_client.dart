import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

abstract class RemoteVideoClient {
  Future<List<RemoteVideoInfo>> listRemoteVideos();

  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id);

  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  });

  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  });
}
