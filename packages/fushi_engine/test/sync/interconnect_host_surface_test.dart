/// 互联 host 的对外面快照（架构重构 A1 的前置护栏，docs/specs/2026-11-28-architecture-redesign.md）：
///
/// 1. `/api/capabilities` **整张表**逐字节快照，两种装配各一份：什么都没接（[_kMinimalCapabilitiesJson]），
///    以及每个能力位都取「最满」那一态（[_kMaximalCapabilitiesJson]）。能力位从手拼 Map 迁到模块表时，键序、
///    「false」与「缺键」两种形态都靠这两份钉住。
/// 2. 端点对照表：每类端点在「没带凭据 / 带 host 凭据」下的状态码与响应体开头（[_kMinimalSurface] 是功能
///    全关，[_kFeaturedSurface] 是功能全接），方法覆盖 GET / HEAD / POST / PUT / DELETE / PROPFIND / MKCOL /
///    OPTIONS。钉住的是鉴权豁免（哪些方法免 Basic）、功能关着回 404 而不掉进 WebDAV 树、方法不对回 405、
///    各门的先后，以及请求确实进了对应的 handler（功能全接时 fake 服务不实现业务，带凭据进到 handler 的请求
///    回 500——这也是被钉住的一态）。
///
/// 期望值是迁移前（develop 4d853cf791）的服务器原样吐出的（把 lib 换回迁移前、`FUSHI_SURFACE_DUMP=1` 录的）；
/// 迁移只许让它们保持不变。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_screen_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:fushi_engine/sync/interconnect_profile_transfer.dart';
import 'package:fushi_engine/sync/interconnect_service_config.dart';
import 'package:fushi_engine/sync/interconnect_source_share.dart';
import 'package:fushi_engine/sync/manga_chapter_progress_sync.dart';
import 'package:fushi_engine/sync/online_library_sync.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String _token = 'surface-token';

/// 什么都没接的 host（`FushiSyncServer(syncDataDir, port, token)`）。
const String _kMinimalCapabilitiesJson =
    '{"srsChangesV1":true,"lookup":{"dictionary":false,"history":false}'
    ',"mining":false,"gameStream":false,"hostUpdate":false,"webdav":{"t'
    'reeListingLevels":2},"liveLibrary":{"dictionaries":false,"books":f'
    'alse,"audio":false,"localAudioContentIdV2":false,"videos":false,"m'
    'anga":false,"videoMetadata":false,"tags":false,"pdfBooks":false,"m'
    'ediaLinks":false,"onlineItems":false,"streamVideos":false,"deletio'
    'nTombstones":false,"videoDeletion":false,"videoTranscode":false,"v'
    'ideoSubtitleDefault":false,"videoSubtitleDefaultEpisode":false,"vi'
    'deoSubtitleClear":false,"videoSidecarSubtitles":false,"videoSideca'
    'rAudio":false,"discShareV1":false,"videoClipExport":false,"videoCl'
    'ipAudioDiscTitle":false,"videoClipAudioDiscTitleAngle":false,"vide'
    'oClipAudioDiscTitleDvd":false,"videoClipAudioDiscTitleDvdAngle":fa'
    'lse,"videoSubtitleBackfill":false,"videoGraphicSubtitleTrack":fals'
    'e,"videoMetadataOrdering":false,"serviceConfig":false,"sourceShare'
    '":false,"pluginRelay":false,"profileTransfer":false},"tls":{"enabl'
    'ed":false},"pairing":{"v2":true}}';

/// 每个能力位都取最满一态的 host（[_maximalServer]）。
const String _kMaximalCapabilitiesJson =
    '{"srsChangesV1":true,"mangaChapterProgress":{"v":1},"lookup":{"dic'
    'tionary":true,"history":true},"mining":true,"gameStream":true,"hos'
    'tUpdate":true,"webdav":{"treeListingLevels":2},"liveLibrary":{"dic'
    'tionaries":true,"books":true,"audio":true,"localAudioContentIdV2":'
    'true,"videos":true,"manga":true,"videoMetadata":true,"tags":true,"'
    'pdfBooks":true,"mediaLinks":true,"onlineItems":true,"streamVideos"'
    ':true,"deletionTombstones":true,"videoDeletion":true,"videoTransco'
    'de":true,"videoSubtitleDefault":true,"videoSubtitleDefaultEpisode"'
    ':true,"videoSubtitleClear":true,"videoSidecarSubtitles":true,"vide'
    'oSidecarAudio":true,"discShareV1":true,"videoClipExport":true,"vid'
    'eoClipAudioDiscTitle":true,"videoClipAudioDiscTitleAngle":true,"vi'
    'deoClipAudioDiscTitleDvd":true,"videoClipAudioDiscTitleDvdAngle":t'
    'rue,"videoSubtitleBackfill":true,"videoGraphicSubtitleTrack":true,'
    '"videoMetadataOrdering":true,"serviceConfig":true,"sourceShare":tr'
    'ue,"pluginRelay":true,"profileTransfer":true},"tls":{"enabled":tru'
    'e,"fingerprint":"aa:bb"},"pairing":{"v2":true},"videoRemoteControl'
    'V1":true,"leaderboardDeviceLinkV1":true,"srsRemoteStoreV2":true,"s'
    'rsRemoteStoreV1":true,"screenOcrV1":true,"aiRelayV1":true}';

/// 功能全关的 host：`方法 路径` → `无凭据结果 / host 凭据结果`（`状态码 体`，体截 60 字符）。
const Map<String, String> _kMinimalSurface = <String, String>{
  'GET /api/pair': '401 / 405',
  'HEAD /api/pair': '401 / 405',
  'POST /api/pair':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair': '401 / 405',
  'DELETE /api/pair': '401 / 405',
  'PROPFIND /api/pair': '401 / 405',
  'MKCOL /api/pair': '401 / 405',
  'OPTIONS /api/pair': '405 / 405',
  'GET /api/pair/v2': '401 / 405',
  'HEAD /api/pair/v2': '401 / 405',
  'POST /api/pair/v2':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2': '401 / 405',
  'DELETE /api/pair/v2': '401 / 405',
  'PROPFIND /api/pair/v2': '401 / 405',
  'MKCOL /api/pair/v2': '401 / 405',
  'OPTIONS /api/pair/v2': '405 / 405',
  'GET /api/pair/v2/confirm': '401 / 405',
  'HEAD /api/pair/v2/confirm': '401 / 405',
  'POST /api/pair/v2/confirm':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2/confirm': '401 / 405',
  'DELETE /api/pair/v2/confirm': '401 / 405',
  'PROPFIND /api/pair/v2/confirm': '401 / 405',
  'MKCOL /api/pair/v2/confirm': '401 / 405',
  'OPTIONS /api/pair/v2/confirm': '405 / 405',
  'GET /api/pair/other': '401 / 404 Not found',
  'HEAD /api/pair/other': '401 / 404',
  'POST /api/pair/other': '401 / 405',
  'DELETE /api/pair/other': '401 / 404 Not found',
  'PROPFIND /api/pair/other': '401 / 404 Not found',
  'OPTIONS /api/pair/other': '200 / 200',
  'GET /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/sessions': '401 / 404',
  'POST /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/sessions':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/sessions/s1': '401 / 404',
  'POST /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/sessions/s1':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/join': '401 / 404',
  'POST /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/join':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/signal': '401 / 404',
  'POST /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/signal':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/stop': '401 / 404',
  'POST /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/stop':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/mine': '401 / 404',
  'POST /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/mine':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/library': '401 / 404',
  'POST /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/library':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/library/cover': '401 / 404',
  'POST /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/library/cover':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/launch': '401 / 404',
  'POST /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/launch':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/launch/status': '401 / 404',
  'POST /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'DELETE /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PROPFIND /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'MKCOL /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'OPTIONS /api/game-stream/launch/status':
      '404 {"version":1,"code":"game_stream_off","error":"Game stream o / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/other': '401 / 404 Not found',
  'HEAD /api/game-stream/other': '401 / 404',
  'POST /api/game-stream/other': '401 / 405',
  'DELETE /api/game-stream/other': '401 / 404 Not found',
  'PROPFIND /api/game-stream/other': '401 / 404 Not found',
  'OPTIONS /api/game-stream/other': '200 / 200',
  'GET /api/video-remote/play': '401 / 405',
  'HEAD /api/video-remote/play': '401 / 405',
  'POST /api/video-remote/play': '401 / 404 Video remote off',
  'PUT /api/video-remote/play': '401 / 405',
  'DELETE /api/video-remote/play': '401 / 405',
  'PROPFIND /api/video-remote/play': '401 / 405',
  'MKCOL /api/video-remote/play': '401 / 405',
  'OPTIONS /api/video-remote/play': '405 / 405',
  'GET /api/video-remote/nope': '401 / 405',
  'HEAD /api/video-remote/nope': '401 / 405',
  'POST /api/video-remote/nope': '401 / 404 Video remote off',
  'PUT /api/video-remote/nope': '401 / 405',
  'DELETE /api/video-remote/nope': '401 / 405',
  'PROPFIND /api/video-remote/nope': '401 / 405',
  'MKCOL /api/video-remote/nope': '401 / 405',
  'OPTIONS /api/video-remote/nope': '405 / 405',
  'GET /api/video-remote': '401 / 404 Not found',
  'HEAD /api/video-remote': '401 / 404',
  'POST /api/video-remote': '401 / 405',
  'DELETE /api/video-remote': '401 / 404 Not found',
  'PROPFIND /api/video-remote': '401 / 404 Not found',
  'OPTIONS /api/video-remote': '200 / 200',
  'GET /api/lookup/word': '401 / 404 Not found',
  'HEAD /api/lookup/word': '401 / 404',
  'POST /api/lookup/word': '401 / 404 Not found',
  'PUT /api/lookup/word': '401 / 404 Not found',
  'DELETE /api/lookup/word': '401 / 404 Not found',
  'PROPFIND /api/lookup/word': '401 / 404 Not found',
  'MKCOL /api/lookup/word': '401 / 404 Not found',
  'OPTIONS /api/lookup/word': '404 Not found / 404 Not found',
  'GET /api/lookup/audio/file': '404 Not found / 404 Not found',
  'HEAD /api/lookup/audio/file': '404 / 404',
  'POST /api/lookup/audio/file': '401 / 405',
  'PUT /api/lookup/audio/file': '401 / 405',
  'DELETE /api/lookup/audio/file': '401 / 405',
  'PROPFIND /api/lookup/audio/file': '401 / 405',
  'MKCOL /api/lookup/audio/file': '401 / 405',
  'OPTIONS /api/lookup/audio/file': '405 / 405',
  'GET /api/lookup': '401 / 404 Not found',
  'HEAD /api/lookup': '401 / 404',
  'POST /api/lookup': '401 / 405',
  'DELETE /api/lookup': '401 / 404 Not found',
  'PROPFIND /api/lookup': '401 / 404 Not found',
  'OPTIONS /api/lookup': '200 / 200',
  'GET /api/mine': '401 / 405',
  'HEAD /api/mine': '401 / 405',
  'POST /api/mine': '401 / 404 Mining off',
  'PUT /api/mine': '401 / 405',
  'DELETE /api/mine': '401 / 405',
  'PROPFIND /api/mine': '401 / 405',
  'MKCOL /api/mine': '401 / 405',
  'OPTIONS /api/mine': '405 / 405',
  'GET /api/mine/targets': '401 / 405',
  'HEAD /api/mine/targets': '401 / 405',
  'POST /api/mine/targets': '401 / 404 Mining targets unavailable',
  'PUT /api/mine/targets': '401 / 405',
  'DELETE /api/mine/targets': '401 / 405',
  'PROPFIND /api/mine/targets': '401 / 405',
  'MKCOL /api/mine/targets': '401 / 405',
  'OPTIONS /api/mine/targets': '405 / 405',
  'GET /api/mine/forward': '401 / 405',
  'HEAD /api/mine/forward': '401 / 405',
  'POST /api/mine/forward': '401 / 404 Mining off',
  'PUT /api/mine/forward': '401 / 405',
  'DELETE /api/mine/forward': '401 / 405',
  'PROPFIND /api/mine/forward': '401 / 405',
  'MKCOL /api/mine/forward': '401 / 405',
  'OPTIONS /api/mine/forward': '405 / 405',
  'GET /api/mine/other': '401 / 404 Not found',
  'HEAD /api/mine/other': '401 / 404',
  'POST /api/mine/other': '401 / 405',
  'DELETE /api/mine/other': '401 / 404 Not found',
  'PROPFIND /api/mine/other': '401 / 404 Not found',
  'OPTIONS /api/mine/other': '200 / 200',
  'GET /api/anki/note-type/x': '401 / 405',
  'HEAD /api/anki/note-type/x': '401 / 405',
  'POST /api/anki/note-type/x': '401 / 404 Mining off',
  'PUT /api/anki/note-type/x': '401 / 405',
  'DELETE /api/anki/note-type/x': '401 / 405',
  'PROPFIND /api/anki/note-type/x': '401 / 405',
  'MKCOL /api/anki/note-type/x': '401 / 405',
  'OPTIONS /api/anki/note-type/x': '405 / 405',
  'GET /api/anki/source/x': '401 / 405',
  'HEAD /api/anki/source/x': '401 / 405',
  'POST /api/anki/source/x': '401 / 404 Source editing unavailable',
  'PUT /api/anki/source/x': '401 / 405',
  'DELETE /api/anki/source/x': '401 / 405',
  'PROPFIND /api/anki/source/x': '401 / 405',
  'MKCOL /api/anki/source/x': '401 / 405',
  'OPTIONS /api/anki/source/x': '405 / 405',
  'GET /api/anki/media/dedup/x': '401 / 405',
  'HEAD /api/anki/media/dedup/x': '401 / 405',
  'POST /api/anki/media/dedup/x': '401 / 404 Mining off',
  'PUT /api/anki/media/dedup/x': '401 / 405',
  'DELETE /api/anki/media/dedup/x': '401 / 405',
  'PROPFIND /api/anki/media/dedup/x': '401 / 405',
  'MKCOL /api/anki/media/dedup/x': '401 / 405',
  'OPTIONS /api/anki/media/dedup/x': '405 / 405',
  'GET /api/anki/other': '401 / 404 Not found',
  'HEAD /api/anki/other': '401 / 404',
  'POST /api/anki/other': '401 / 405',
  'DELETE /api/anki/other': '401 / 404 Not found',
  'PROPFIND /api/anki/other': '401 / 404 Not found',
  'OPTIONS /api/anki/other': '200 / 200',
  'GET /api/media/dictionary': '401 / 404 Media off',
  'HEAD /api/media/dictionary': '401 / 404',
  'POST /api/media/dictionary': '401 / 405',
  'PUT /api/media/dictionary': '401 / 405',
  'DELETE /api/media/dictionary': '401 / 405',
  'PROPFIND /api/media/dictionary': '401 / 405',
  'MKCOL /api/media/dictionary': '401 / 405',
  'OPTIONS /api/media/dictionary': '405 / 405',
  'GET /api/media/dictionary?dictionary=d&path=a.svg&key=bad':
      '401 / 404 Media off',
  'HEAD /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 404',
  'POST /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'PUT /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'DELETE /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'PROPFIND /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'MKCOL /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'OPTIONS /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '405 / 405',
  'GET /api/duplicate': '401 / 405',
  'HEAD /api/duplicate': '401 / 405',
  'POST /api/duplicate': '401 / 400 Invalid JSON',
  'PUT /api/duplicate': '401 / 405',
  'DELETE /api/duplicate': '401 / 405',
  'PROPFIND /api/duplicate': '401 / 405',
  'MKCOL /api/duplicate': '401 / 405',
  'OPTIONS /api/duplicate': '405 / 405',
  'GET /api/extension/status': '401 / 405',
  'HEAD /api/extension/status': '401 / 405',
  'POST /api/extension/status':
      '401 / 200 {"app":"fushi","ready":true,"port":<port>,"dictionaryMediaKe',
  'PUT /api/extension/status': '401 / 405',
  'DELETE /api/extension/status': '401 / 405',
  'PROPFIND /api/extension/status': '401 / 405',
  'MKCOL /api/extension/status': '401 / 405',
  'OPTIONS /api/extension/status': '405 / 405',
  'GET /api/ping':
      '200 {"app":"fushi","pairing":{"v2":true},"tls":{"enabled":false} / 200 {"app":"fushi","pairing":{"v2":true},"tls":{"enabled":false}',
  'HEAD /api/ping': '401 / 405',
  'POST /api/ping': '401 / 405',
  'PUT /api/ping': '401 / 405',
  'DELETE /api/ping': '401 / 405',
  'PROPFIND /api/ping': '401 / 405',
  'MKCOL /api/ping': '401 / 405',
  'OPTIONS /api/ping': '405 / 405',
  'GET /api/srs/changes': '401 / 200 {"token":<n>,"own":false}',
  'HEAD /api/srs/changes': '401 / 405',
  'POST /api/srs/changes': '401 / 405',
  'PUT /api/srs/changes': '401 / 405',
  'DELETE /api/srs/changes': '401 / 405',
  'PROPFIND /api/srs/changes': '401 / 405',
  'MKCOL /api/srs/changes': '401 / 405',
  'OPTIONS /api/srs/changes': '405 / 405',
  'GET /api/srs/sync-status': '401 / 404 SRS sync status not reported',
  'HEAD /api/srs/sync-status': '401 / 405',
  'POST /api/srs/sync-status': '401 / 405',
  'PUT /api/srs/sync-status': '401 / 405',
  'DELETE /api/srs/sync-status': '401 / 405',
  'PROPFIND /api/srs/sync-status': '401 / 405',
  'MKCOL /api/srs/sync-status': '401 / 405',
  'OPTIONS /api/srs/sync-status': '405 / 405',
  'GET /api/srs/remote/review': '401 / 404 SRS review off',
  'HEAD /api/srs/remote/review': '401 / 404',
  'POST /api/srs/remote/review': '401 / 404 SRS review off',
  'PUT /api/srs/remote/review': '401 / 404 SRS review off',
  'DELETE /api/srs/remote/review': '401 / 404 SRS review off',
  'PROPFIND /api/srs/remote/review': '401 / 404 SRS review off',
  'MKCOL /api/srs/remote/review': '401 / 404 SRS review off',
  'OPTIONS /api/srs/remote/review': '404 SRS review off / 404 SRS review off',
  'GET /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'HEAD /api/srs/remote2/review': '401 / 503',
  'POST /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'PUT /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'DELETE /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'PROPFIND /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'MKCOL /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'OPTIONS /api/srs/remote2/review':
      '503 {"error":"unavailable"} / 503 {"error":"unavailable"}',
  'GET /api/srs/other': '401 / 404 Not found',
  'HEAD /api/srs/other': '401 / 404',
  'POST /api/srs/other': '401 / 405',
  'DELETE /api/srs/other': '401 / 404 Not found',
  'PROPFIND /api/srs/other': '401 / 404 Not found',
  'OPTIONS /api/srs/other': '200 / 200',
  'GET /api/ai/relay/providers': '401 / 404 AI relay off',
  'HEAD /api/ai/relay/providers': '401 / 404',
  'POST /api/ai/relay/providers': '401 / 404 AI relay off',
  'PUT /api/ai/relay/providers': '401 / 404 AI relay off',
  'DELETE /api/ai/relay/providers': '401 / 404 AI relay off',
  'PROPFIND /api/ai/relay/providers': '401 / 404 AI relay off',
  'MKCOL /api/ai/relay/providers': '401 / 404 AI relay off',
  'OPTIONS /api/ai/relay/providers': '404 AI relay off / 404 AI relay off',
  'GET /api/ai/relay': '401 / 404 Not found',
  'HEAD /api/ai/relay': '401 / 404',
  'POST /api/ai/relay': '401 / 405',
  'DELETE /api/ai/relay': '401 / 404 Not found',
  'PROPFIND /api/ai/relay': '401 / 404 Not found',
  'OPTIONS /api/ai/relay': '200 / 200',
  'GET /api/capabilities':
      '401 / 200 {"srsChangesV1":true,"lookup":{"dictionary":false,"history":',
  'HEAD /api/capabilities': '401 / 405',
  'POST /api/capabilities': '401 / 405',
  'PUT /api/capabilities': '401 / 405',
  'DELETE /api/capabilities': '401 / 405',
  'PROPFIND /api/capabilities': '401 / 405',
  'MKCOL /api/capabilities': '401 / 405',
  'OPTIONS /api/capabilities': '405 / 405',
  'GET /api/host/addresses': '401 / 404 No host id',
  'HEAD /api/host/addresses': '401 / 405',
  'POST /api/host/addresses': '401 / 405',
  'PUT /api/host/addresses': '401 / 405',
  'DELETE /api/host/addresses': '401 / 405',
  'PROPFIND /api/host/addresses': '401 / 405',
  'MKCOL /api/host/addresses': '401 / 405',
  'OPTIONS /api/host/addresses': '405 / 405',
  'GET /api/host/update': '401 / 404 Host update off',
  'HEAD /api/host/update': '401 / 405',
  'POST /api/host/update': '401 / 404 Host update off',
  'PUT /api/host/update': '401 / 405',
  'DELETE /api/host/update': '401 / 405',
  'PROPFIND /api/host/update': '401 / 405',
  'MKCOL /api/host/update': '401 / 405',
  'OPTIONS /api/host/update': '405 / 405',
  'GET /api/ocr/screen': '401 / 404 Screen OCR off',
  'HEAD /api/ocr/screen': '401 / 404',
  'POST /api/ocr/screen': '401 / 404 Screen OCR off',
  'PUT /api/ocr/screen': '401 / 404 Screen OCR off',
  'DELETE /api/ocr/screen': '401 / 404 Screen OCR off',
  'PROPFIND /api/ocr/screen': '401 / 404 Screen OCR off',
  'MKCOL /api/ocr/screen': '401 / 404 Screen OCR off',
  'OPTIONS /api/ocr/screen': '404 Screen OCR off / 404 Screen OCR off',
  'GET /api/ocr/job': '401 / 404 Manga OCR off',
  'HEAD /api/ocr/job': '401 / 404',
  'POST /api/ocr/job': '401 / 404 Manga OCR off',
  'PUT /api/ocr/job': '401 / 404 Manga OCR off',
  'DELETE /api/ocr/job': '401 / 404 Manga OCR off',
  'PROPFIND /api/ocr/job': '401 / 404 Manga OCR off',
  'MKCOL /api/ocr/job': '401 / 404 Manga OCR off',
  'OPTIONS /api/ocr/job': '404 Manga OCR off / 404 Manga OCR off',
  'GET /api/jobs': '401 / 404 Host jobs off',
  'HEAD /api/jobs': '401 / 404',
  'POST /api/jobs': '401 / 404 Host jobs off',
  'PUT /api/jobs': '401 / 404 Host jobs off',
  'DELETE /api/jobs': '401 / 404 Host jobs off',
  'PROPFIND /api/jobs': '401 / 404 Host jobs off',
  'MKCOL /api/jobs': '401 / 404 Host jobs off',
  'OPTIONS /api/jobs': '404 Host jobs off / 404 Host jobs off',
  'GET /api/downloads': '401 / 404 Host downloads off',
  'HEAD /api/downloads': '401 / 404',
  'POST /api/downloads': '401 / 404 Host downloads off',
  'PUT /api/downloads': '401 / 404 Host downloads off',
  'DELETE /api/downloads': '401 / 404 Host downloads off',
  'PROPFIND /api/downloads': '401 / 404 Host downloads off',
  'MKCOL /api/downloads': '401 / 404 Host downloads off',
  'OPTIONS /api/downloads': '404 Host downloads off / 404 Host downloads off',
  'GET /api/torrent-engine': '401 / 404 Host torrent engine off',
  'HEAD /api/torrent-engine': '401 / 404',
  'POST /api/torrent-engine': '401 / 404 Host torrent engine off',
  'PUT /api/torrent-engine': '401 / 404 Host torrent engine off',
  'DELETE /api/torrent-engine': '401 / 404 Host torrent engine off',
  'PROPFIND /api/torrent-engine': '401 / 404 Host torrent engine off',
  'MKCOL /api/torrent-engine': '401 / 404 Host torrent engine off',
  'OPTIONS /api/torrent-engine':
      '404 Host torrent engine off / 404 Host torrent engine off',
  'GET /api/subscriptions': '401 / 404 Host subscriptions off',
  'HEAD /api/subscriptions': '401 / 404',
  'POST /api/subscriptions': '401 / 404 Host subscriptions off',
  'PUT /api/subscriptions': '401 / 404 Host subscriptions off',
  'DELETE /api/subscriptions': '401 / 404 Host subscriptions off',
  'PROPFIND /api/subscriptions': '401 / 404 Host subscriptions off',
  'MKCOL /api/subscriptions': '401 / 404 Host subscriptions off',
  'OPTIONS /api/subscriptions':
      '404 Host subscriptions off / 404 Host subscriptions off',
  'GET /api/assistant': '401 / 404 Host assistant off',
  'HEAD /api/assistant': '401 / 404',
  'POST /api/assistant': '401 / 404 Host assistant off',
  'PUT /api/assistant': '401 / 404 Host assistant off',
  'DELETE /api/assistant': '401 / 404 Host assistant off',
  'PROPFIND /api/assistant': '401 / 404 Host assistant off',
  'MKCOL /api/assistant': '401 / 404 Host assistant off',
  'OPTIONS /api/assistant': '404 Host assistant off / 404 Host assistant off',
  'GET /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'HEAD /api/library/manga-chapter-progress': '401 / 404',
  'POST /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'PUT /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'DELETE /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'PROPFIND /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'MKCOL /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'OPTIONS /api/library/manga-chapter-progress':
      '404 Manga chapter progress unsupported / 404 Manga chapter progress unsupported',
  'GET /api/library/music': '401 / 404 Not found',
  'HEAD /api/library/music': '401 / 404',
  'POST /api/library/music': '401 / 405',
  'DELETE /api/library/music': '401 / 404 Not found',
  'PROPFIND /api/library/music': '401 / 404 Not found',
  'OPTIONS /api/library/music': '200 / 200',
  'GET /api/library/media/streamurl': '401 / 405',
  'HEAD /api/library/media/streamurl': '401 / 405',
  'POST /api/library/media/streamurl': '401 / 400 Invalid JSON',
  'PUT /api/library/media/streamurl': '401 / 405',
  'DELETE /api/library/media/streamurl': '401 / 405',
  'PROPFIND /api/library/media/streamurl': '401 / 405',
  'MKCOL /api/library/media/streamurl': '401 / 405',
  'OPTIONS /api/library/media/streamurl': '405 / 405',
  'GET /api/library/media/stream': '401 Missing token / 401 Missing token',
  'HEAD /api/library/media/stream': '401 / 401',
  'POST /api/library/media/stream': '401 / 405',
  'PUT /api/library/media/stream': '401 / 405',
  'DELETE /api/library/media/stream': '401 / 405',
  'PROPFIND /api/library/media/stream': '401 / 405',
  'MKCOL /api/library/media/stream': '401 / 405',
  'OPTIONS /api/library/media/stream': '405 / 405',
  'GET /api/library/media/stream?token=bad':
      '403 Invalid or expired token / 403 Invalid or expired token',
  'HEAD /api/library/media/stream?token=bad': '403 / 403',
  'POST /api/library/media/stream?token=bad': '401 / 405',
  'PUT /api/library/media/stream?token=bad': '401 / 405',
  'DELETE /api/library/media/stream?token=bad': '401 / 405',
  'PROPFIND /api/library/media/stream?token=bad': '401 / 405',
  'MKCOL /api/library/media/stream?token=bad': '401 / 405',
  'OPTIONS /api/library/media/stream?token=bad': '405 / 405',
  'GET /api/library/media/streamrelease': '401 / 405',
  'HEAD /api/library/media/streamrelease': '401 / 405',
  'POST /api/library/media/streamrelease': '401 / 400 Missing ticket',
  'PUT /api/library/media/streamrelease': '401 / 405',
  'DELETE /api/library/media/streamrelease': '401 / 405',
  'PROPFIND /api/library/media/streamrelease': '401 / 405',
  'MKCOL /api/library/media/streamrelease': '401 / 405',
  'OPTIONS /api/library/media/streamrelease': '405 / 405',
  'GET /api/library/dictionaries': '401 / 404 Library service off',
  'HEAD /api/library/dictionaries': '401 / 404',
  'POST /api/library/dictionaries': '401 / 404 Library service off',
  'PUT /api/library/dictionaries': '401 / 404 Library service off',
  'DELETE /api/library/dictionaries': '401 / 404 Library service off',
  'PROPFIND /api/library/dictionaries': '401 / 404 Library service off',
  'MKCOL /api/library/dictionaries': '401 / 404 Library service off',
  'OPTIONS /api/library/dictionaries':
      '404 Library service off / 404 Library service off',
  'GET /api/library/dictionaries/d1': '401 / 404 Library service off',
  'HEAD /api/library/dictionaries/d1': '401 / 404',
  'POST /api/library/dictionaries/d1': '401 / 404 Library service off',
  'PUT /api/library/dictionaries/d1': '401 / 404 Library service off',
  'DELETE /api/library/dictionaries/d1': '401 / 404 Library service off',
  'PROPFIND /api/library/dictionaries/d1': '401 / 404 Library service off',
  'MKCOL /api/library/dictionaries/d1': '401 / 404 Library service off',
  'OPTIONS /api/library/dictionaries/d1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/book-progress': '401 / 404 Book progress batch unsupported',
  'HEAD /api/library/book-progress': '401 / 404',
  'POST /api/library/book-progress':
      '401 / 404 Book progress batch unsupported',
  'PUT /api/library/book-progress': '401 / 404 Book progress batch unsupported',
  'DELETE /api/library/book-progress':
      '401 / 404 Book progress batch unsupported',
  'PROPFIND /api/library/book-progress':
      '401 / 404 Book progress batch unsupported',
  'MKCOL /api/library/book-progress':
      '401 / 404 Book progress batch unsupported',
  'OPTIONS /api/library/book-progress':
      '404 Book progress batch unsupported / 404 Book progress batch unsupported',
  'GET /api/library/books': '401 / 404 Library service off',
  'HEAD /api/library/books': '401 / 404',
  'POST /api/library/books': '401 / 404 Library service off',
  'PUT /api/library/books': '401 / 404 Library service off',
  'DELETE /api/library/books': '401 / 404 Library service off',
  'PROPFIND /api/library/books': '401 / 404 Library service off',
  'MKCOL /api/library/books': '401 / 404 Library service off',
  'OPTIONS /api/library/books':
      '404 Library service off / 404 Library service off',
  'GET /api/library/books/b1': '401 / 404 Library service off',
  'HEAD /api/library/books/b1': '401 / 404',
  'POST /api/library/books/b1': '401 / 404 Library service off',
  'PUT /api/library/books/b1': '401 / 404 Library service off',
  'DELETE /api/library/books/b1': '401 / 404 Library service off',
  'PROPFIND /api/library/books/b1': '401 / 404 Library service off',
  'MKCOL /api/library/books/b1': '401 / 404 Library service off',
  'OPTIONS /api/library/books/b1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/manga': '401 / 404 Not found',
  'HEAD /api/library/manga': '401 / 404',
  'POST /api/library/manga': '401 / 405',
  'DELETE /api/library/manga': '401 / 404 Not found',
  'PROPFIND /api/library/manga': '401 / 404 Not found',
  'OPTIONS /api/library/manga': '200 / 200',
  'GET /api/library/manga/m1': '401 / 404 Library service off',
  'HEAD /api/library/manga/m1': '401 / 404',
  'POST /api/library/manga/m1': '401 / 404 Library service off',
  'PUT /api/library/manga/m1': '401 / 404 Library service off',
  'DELETE /api/library/manga/m1': '401 / 404 Library service off',
  'PROPFIND /api/library/manga/m1': '401 / 404 Library service off',
  'MKCOL /api/library/manga/m1': '401 / 404 Library service off',
  'OPTIONS /api/library/manga/m1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/localaudio': '401 / 404 Library service off',
  'HEAD /api/library/localaudio': '401 / 404',
  'POST /api/library/localaudio': '401 / 404 Library service off',
  'PUT /api/library/localaudio': '401 / 404 Library service off',
  'DELETE /api/library/localaudio': '401 / 404 Library service off',
  'PROPFIND /api/library/localaudio': '401 / 404 Library service off',
  'MKCOL /api/library/localaudio': '401 / 404 Library service off',
  'OPTIONS /api/library/localaudio':
      '404 Library service off / 404 Library service off',
  'GET /api/library/localaudio/a1': '401 / 404 Library service off',
  'HEAD /api/library/localaudio/a1': '401 / 404',
  'POST /api/library/localaudio/a1': '401 / 404 Library service off',
  'PUT /api/library/localaudio/a1': '401 / 404 Library service off',
  'DELETE /api/library/localaudio/a1': '401 / 404 Library service off',
  'PROPFIND /api/library/localaudio/a1': '401 / 404 Library service off',
  'MKCOL /api/library/localaudio/a1': '401 / 404 Library service off',
  'OPTIONS /api/library/localaudio/a1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/audiobooks': '401 / 404 Library service off',
  'HEAD /api/library/audiobooks': '401 / 404',
  'POST /api/library/audiobooks': '401 / 404 Library service off',
  'PUT /api/library/audiobooks': '401 / 404 Library service off',
  'DELETE /api/library/audiobooks': '401 / 404 Library service off',
  'PROPFIND /api/library/audiobooks': '401 / 404 Library service off',
  'MKCOL /api/library/audiobooks': '401 / 404 Library service off',
  'OPTIONS /api/library/audiobooks':
      '404 Library service off / 404 Library service off',
  'GET /api/library/audiobooks/a1': '401 / 404 Library service off',
  'HEAD /api/library/audiobooks/a1': '401 / 404',
  'POST /api/library/audiobooks/a1': '401 / 404 Library service off',
  'PUT /api/library/audiobooks/a1': '401 / 404 Library service off',
  'DELETE /api/library/audiobooks/a1': '401 / 404 Library service off',
  'PROPFIND /api/library/audiobooks/a1': '401 / 404 Library service off',
  'MKCOL /api/library/audiobooks/a1': '401 / 404 Library service off',
  'OPTIONS /api/library/audiobooks/a1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/metadata': '401 / 404 Video metadata host off',
  'HEAD /api/library/metadata': '401 / 404',
  'POST /api/library/metadata': '401 / 404 Video metadata host off',
  'PUT /api/library/metadata': '401 / 404 Video metadata host off',
  'DELETE /api/library/metadata': '401 / 404 Video metadata host off',
  'PROPFIND /api/library/metadata': '401 / 404 Video metadata host off',
  'MKCOL /api/library/metadata': '401 / 404 Video metadata host off',
  'OPTIONS /api/library/metadata':
      '404 Video metadata host off / 404 Video metadata host off',
  'GET /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'HEAD /api/library/metadata/v1': '401 / 404',
  'POST /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'PUT /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'DELETE /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'PROPFIND /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'MKCOL /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'OPTIONS /api/library/metadata/v1':
      '404 Video metadata host off / 404 Video metadata host off',
  'GET /api/library/videos': '401 / 404 Library service off',
  'HEAD /api/library/videos': '401 / 404',
  'POST /api/library/videos': '401 / 404 Library service off',
  'PUT /api/library/videos': '401 / 404 Library service off',
  'DELETE /api/library/videos': '401 / 404 Library service off',
  'PROPFIND /api/library/videos': '401 / 404 Library service off',
  'MKCOL /api/library/videos': '401 / 404 Library service off',
  'OPTIONS /api/library/videos':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1': '401 / 404',
  'POST /api/library/videos/v1': '401 / 404 Library service off',
  'PUT /api/library/videos/v1': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1/streamurl': '401 / 404',
  'POST /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/streamurl':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/stream':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/stream': '401 / 404',
  'POST /api/library/videos/v1/stream': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/stream': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/stream': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/stream': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/stream': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/stream':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/stream?token=bad':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/stream?token=bad': '401 / 404',
  'POST /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'PUT /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/stream?token=bad':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/hls.m3u8':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/hls.m3u8': '401 / 404',
  'POST /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/hls.m3u8':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/hlsseg.ts':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/hlsseg.ts': '401 / 404',
  'POST /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/hlsseg.ts':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/bdclip.m2ts':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/bdclip.m2ts': '401 / 404',
  'POST /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/bdclip.m2ts':
      '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/bdclip.m2ts':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/sidecaraudio':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/sidecaraudio': '401 / 404',
  'POST /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/sidecaraudio':
      '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/sidecaraudio':
      '404 Library service off / 404 Library service off',
  'GET /api/library/videos/v1/disc': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1/disc': '401 / 404',
  'POST /api/library/videos/v1/disc': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/disc': '401 / 404 Library service off',
  'DELETE /api/library/videos/v1/disc': '401 / 404 Library service off',
  'PROPFIND /api/library/videos/v1/disc': '401 / 404 Library service off',
  'MKCOL /api/library/videos/v1/disc': '401 / 404 Library service off',
  'OPTIONS /api/library/videos/v1/disc':
      '404 Library service off / 404 Library service off',
  'GET /api/library/disc/t1/BDMV/index.bdmv':
      '404 Disc share off / 404 Disc share off',
  'HEAD /api/library/disc/t1/BDMV/index.bdmv': '401 / 404',
  'POST /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'PUT /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'DELETE /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'PROPFIND /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'MKCOL /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'OPTIONS /api/library/disc/t1/BDMV/index.bdmv':
      '404 Disc share off / 404 Disc share off',
  'GET /api/library/disc': '401 / 404 Not found',
  'HEAD /api/library/disc': '401 / 404',
  'POST /api/library/disc': '401 / 405',
  'DELETE /api/library/disc': '401 / 404 Not found',
  'PROPFIND /api/library/disc': '401 / 404 Not found',
  'OPTIONS /api/library/disc': '200 / 200',
  'GET /api/library/aggregate': '401 / 404 Library service off',
  'HEAD /api/library/aggregate': '401 / 404',
  'POST /api/library/aggregate': '401 / 404 Library service off',
  'PUT /api/library/aggregate': '401 / 404 Library service off',
  'DELETE /api/library/aggregate': '401 / 404 Library service off',
  'PROPFIND /api/library/aggregate': '401 / 404 Library service off',
  'MKCOL /api/library/aggregate': '401 / 404 Library service off',
  'OPTIONS /api/library/aggregate':
      '404 Library service off / 404 Library service off',
  'GET /api/library/activity': '401 / 404 Library service off',
  'HEAD /api/library/activity': '401 / 404',
  'POST /api/library/activity': '401 / 404 Library service off',
  'PUT /api/library/activity': '401 / 404 Library service off',
  'DELETE /api/library/activity': '401 / 404 Library service off',
  'PROPFIND /api/library/activity': '401 / 404 Library service off',
  'MKCOL /api/library/activity': '401 / 404 Library service off',
  'OPTIONS /api/library/activity':
      '404 Library service off / 404 Library service off',
  'GET /api/library/collections': '401 / 404 Library service off',
  'HEAD /api/library/collections': '401 / 404',
  'POST /api/library/collections': '401 / 404 Library service off',
  'PUT /api/library/collections': '401 / 404 Library service off',
  'DELETE /api/library/collections': '401 / 404 Library service off',
  'PROPFIND /api/library/collections': '401 / 404 Library service off',
  'MKCOL /api/library/collections': '401 / 404 Library service off',
  'OPTIONS /api/library/collections':
      '404 Library service off / 404 Library service off',
  'GET /api/library/tags': '401 / 404 Tag sync off',
  'HEAD /api/library/tags': '401 / 404',
  'POST /api/library/tags': '401 / 404 Tag sync off',
  'PUT /api/library/tags': '401 / 404 Tag sync off',
  'DELETE /api/library/tags': '401 / 404 Tag sync off',
  'PROPFIND /api/library/tags': '401 / 404 Tag sync off',
  'MKCOL /api/library/tags': '401 / 404 Tag sync off',
  'OPTIONS /api/library/tags': '404 Tag sync off / 404 Tag sync off',
  'GET /api/library/media-links': '401 / 404 Media link sync off',
  'HEAD /api/library/media-links': '401 / 404',
  'POST /api/library/media-links': '401 / 404 Media link sync off',
  'PUT /api/library/media-links': '401 / 404 Media link sync off',
  'DELETE /api/library/media-links': '401 / 404 Media link sync off',
  'PROPFIND /api/library/media-links': '401 / 404 Media link sync off',
  'MKCOL /api/library/media-links': '401 / 404 Media link sync off',
  'OPTIONS /api/library/media-links':
      '404 Media link sync off / 404 Media link sync off',
  'GET /api/library/online-items': '401 / 404 Online library sync off',
  'HEAD /api/library/online-items': '401 / 404',
  'POST /api/library/online-items': '401 / 404 Online library sync off',
  'PUT /api/library/online-items': '401 / 404 Online library sync off',
  'DELETE /api/library/online-items': '401 / 404 Online library sync off',
  'PROPFIND /api/library/online-items': '401 / 404 Online library sync off',
  'MKCOL /api/library/online-items': '401 / 404 Online library sync off',
  'OPTIONS /api/library/online-items':
      '404 Online library sync off / 404 Online library sync off',
  'GET /api/library/other': '401 / 404 Not found',
  'HEAD /api/library/other': '401 / 404',
  'POST /api/library/other': '401 / 405',
  'DELETE /api/library/other': '401 / 404 Not found',
  'PROPFIND /api/library/other': '401 / 404 Not found',
  'OPTIONS /api/library/other': '200 / 200',
  'GET /api/interconnect/service-config':
      '401 / 403 HTTPS required for service config',
  'HEAD /api/interconnect/service-config': '401 / 405',
  'POST /api/interconnect/service-config': '401 / 405',
  'PUT /api/interconnect/service-config': '401 / 405',
  'DELETE /api/interconnect/service-config': '401 / 405',
  'PROPFIND /api/interconnect/service-config': '401 / 405',
  'MKCOL /api/interconnect/service-config': '401 / 405',
  'OPTIONS /api/interconnect/service-config': '405 / 405',
  'GET /api/interconnect/source-share': '401 / 404 Source share capability off',
  'HEAD /api/interconnect/source-share': '401 / 405',
  'POST /api/interconnect/source-share': '401 / 405',
  'PUT /api/interconnect/source-share': '401 / 405',
  'DELETE /api/interconnect/source-share': '401 / 405',
  'PROPFIND /api/interconnect/source-share': '401 / 405',
  'MKCOL /api/interconnect/source-share': '401 / 405',
  'OPTIONS /api/interconnect/source-share': '405 / 405',
  'GET /api/interconnect/source-share/package':
      '401 / 404 Source share capability off',
  'HEAD /api/interconnect/source-share/package': '401 / 405',
  'POST /api/interconnect/source-share/package': '401 / 405',
  'PUT /api/interconnect/source-share/package': '401 / 405',
  'DELETE /api/interconnect/source-share/package': '401 / 405',
  'PROPFIND /api/interconnect/source-share/package': '401 / 405',
  'MKCOL /api/interconnect/source-share/package': '401 / 405',
  'OPTIONS /api/interconnect/source-share/package': '405 / 405',
  'GET /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay': '401 / 404',
  'POST /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'DELETE /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'PROPFIND /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'MKCOL /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'OPTIONS /api/interconnect/plugin-relay':
      '404 Plugin relay off / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/invoke': '401 / 404',
  'POST /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'DELETE /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'PROPFIND /api/interconnect/plugin-relay/invoke':
      '401 / 404 Plugin relay off',
  'MKCOL /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'OPTIONS /api/interconnect/plugin-relay/invoke':
      '404 Plugin relay off / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/stream/t1':
      '404 Plugin relay off / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/stream/t1': '404 / 404',
  'POST /api/interconnect/plugin-relay/stream/t1': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay/stream/t1': '401 / 404 Plugin relay off',
  'DELETE /api/interconnect/plugin-relay/stream/t1':
      '401 / 404 Plugin relay off',
  'PROPFIND /api/interconnect/plugin-relay/stream/t1':
      '401 / 404 Plugin relay off',
  'MKCOL /api/interconnect/plugin-relay/stream/t1':
      '401 / 404 Plugin relay off',
  'OPTIONS /api/interconnect/plugin-relay/stream/t1':
      '404 Plugin relay off / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/stream/': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/stream/': '401 / 404',
  'POST /api/interconnect/plugin-relay/stream/': '401 / 404 Plugin relay off',
  'DELETE /api/interconnect/plugin-relay/stream/': '401 / 404 Plugin relay off',
  'PROPFIND /api/interconnect/plugin-relay/stream/':
      '401 / 404 Plugin relay off',
  'OPTIONS /api/interconnect/plugin-relay/stream/':
      '404 Plugin relay off / 404 Plugin relay off',
  'GET /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/profile': '401 / 405',
  'POST /api/interconnect/profile': '401 / 405',
  'PUT /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'DELETE /api/interconnect/profile': '401 / 405',
  'PROPFIND /api/interconnect/profile': '401 / 405',
  'MKCOL /api/interconnect/profile': '401 / 405',
  'OPTIONS /api/interconnect/profile': '405 / 405',
  'GET /api/interconnect/leaderboard-link': '401 / 405',
  'HEAD /api/interconnect/leaderboard-link': '401 / 405',
  'POST /api/interconnect/leaderboard-link':
      '401 / 403 {"error":"https_required"}',
  'PUT /api/interconnect/leaderboard-link': '401 / 405',
  'DELETE /api/interconnect/leaderboard-link': '401 / 405',
  'PROPFIND /api/interconnect/leaderboard-link': '401 / 405',
  'MKCOL /api/interconnect/leaderboard-link': '401 / 405',
  'OPTIONS /api/interconnect/leaderboard-link': '405 / 405',
  'GET /api/interconnect/other': '401 / 404 Not found',
  'HEAD /api/interconnect/other': '401 / 404',
  'POST /api/interconnect/other': '401 / 405',
  'DELETE /api/interconnect/other': '401 / 404 Not found',
  'PROPFIND /api/interconnect/other': '401 / 404 Not found',
  'OPTIONS /api/interconnect/other': '200 / 200',
  'GET /api/tombstones': '401 / 404 Library service off',
  'HEAD /api/tombstones': '401 / 405',
  'POST /api/tombstones': '401 / 405',
  'PUT /api/tombstones': '401 / 405',
  'DELETE /api/tombstones': '401 / 405',
  'PROPFIND /api/tombstones': '401 / 405',
  'MKCOL /api/tombstones': '401 / 405',
  'OPTIONS /api/tombstones': '405 / 405',
  'GET /api/unknown': '401 / 404 Not found',
  'HEAD /api/unknown': '401 / 404',
  'POST /api/unknown': '401 / 405',
  'DELETE /api/unknown': '401 / 404 Not found',
  'PROPFIND /api/unknown': '401 / 404 Not found',
  'OPTIONS /api/unknown': '200 / 200',
};

/// 功能全接（明文 HTTP）的 host：`方法 路径` → `无凭据结果 / host 凭据结果`。
const Map<String, String> _kFeaturedSurface = <String, String>{
  'GET /api/pair': '401 / 405',
  'HEAD /api/pair': '401 / 405',
  'POST /api/pair':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair': '401 / 405',
  'DELETE /api/pair': '401 / 405',
  'PROPFIND /api/pair': '401 / 405',
  'MKCOL /api/pair': '401 / 405',
  'OPTIONS /api/pair': '405 / 405',
  'GET /api/pair/v2': '401 / 405',
  'HEAD /api/pair/v2': '401 / 405',
  'POST /api/pair/v2':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2': '401 / 405',
  'DELETE /api/pair/v2': '401 / 405',
  'PROPFIND /api/pair/v2': '401 / 405',
  'MKCOL /api/pair/v2': '401 / 405',
  'OPTIONS /api/pair/v2': '405 / 405',
  'GET /api/pair/v2/confirm': '401 / 405',
  'HEAD /api/pair/v2/confirm': '401 / 405',
  'POST /api/pair/v2/confirm':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2/confirm': '401 / 405',
  'DELETE /api/pair/v2/confirm': '401 / 405',
  'PROPFIND /api/pair/v2/confirm': '401 / 405',
  'MKCOL /api/pair/v2/confirm': '401 / 405',
  'OPTIONS /api/pair/v2/confirm': '405 / 405',
  'GET /api/pair/other': '401 / 404 Not found',
  'HEAD /api/pair/other': '401 / 404',
  'POST /api/pair/other': '401 / 405',
  'DELETE /api/pair/other': '401 / 404 Not found',
  'PROPFIND /api/pair/other': '401 / 404 Not found',
  'OPTIONS /api/pair/other': '200 / 200',
  'GET /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/sessions': '401 / 403',
  'POST /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/sessions':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/sessions':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/sessions/s1': '401 / 403',
  'POST /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/sessions/s1':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/sessions/s1':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/join': '401 / 403',
  'POST /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/join':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/join':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/signal': '401 / 403',
  'POST /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/signal':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/signal':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/stop': '401 / 403',
  'POST /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/stop':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/stop':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/mine': '401 / 403',
  'POST /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/mine':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/mine':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/library': '401 / 403',
  'POST /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/library':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/library':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/library/cover': '401 / 403',
  'POST /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/library/cover':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/library/cover':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/launch': '401 / 403',
  'POST /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/launch':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/launch':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'HEAD /api/game-stream/launch/status': '401 / 403',
  'POST /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PUT /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'DELETE /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'PROPFIND /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'MKCOL /api/game-stream/launch/status':
      '401 / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'OPTIONS /api/game-stream/launch/status':
      '403 {"version":1,"code":"https_required","error":"HTTPS required / 403 {"version":1,"code":"https_required","error":"HTTPS required',
  'GET /api/game-stream/other': '401 / 404 Not found',
  'HEAD /api/game-stream/other': '401 / 404',
  'POST /api/game-stream/other': '401 / 405',
  'DELETE /api/game-stream/other': '401 / 404 Not found',
  'PROPFIND /api/game-stream/other': '401 / 404 Not found',
  'OPTIONS /api/game-stream/other': '200 / 200',
  'GET /api/video-remote/play': '401 / 405',
  'HEAD /api/video-remote/play': '401 / 405',
  'POST /api/video-remote/play': '401 / 404 Unknown video remote operation',
  'PUT /api/video-remote/play': '401 / 405',
  'DELETE /api/video-remote/play': '401 / 405',
  'PROPFIND /api/video-remote/play': '401 / 405',
  'MKCOL /api/video-remote/play': '401 / 405',
  'OPTIONS /api/video-remote/play': '405 / 405',
  'GET /api/video-remote/nope': '401 / 405',
  'HEAD /api/video-remote/nope': '401 / 405',
  'POST /api/video-remote/nope': '401 / 404 Unknown video remote operation',
  'PUT /api/video-remote/nope': '401 / 405',
  'DELETE /api/video-remote/nope': '401 / 405',
  'PROPFIND /api/video-remote/nope': '401 / 405',
  'MKCOL /api/video-remote/nope': '401 / 405',
  'OPTIONS /api/video-remote/nope': '405 / 405',
  'GET /api/video-remote': '401 / 404 Not found',
  'HEAD /api/video-remote': '401 / 404',
  'POST /api/video-remote': '401 / 405',
  'DELETE /api/video-remote': '401 / 404 Not found',
  'PROPFIND /api/video-remote': '401 / 404 Not found',
  'OPTIONS /api/video-remote': '200 / 200',
  'GET /api/lookup/word': '401 / 404 Not found',
  'HEAD /api/lookup/word': '401 / 404',
  'POST /api/lookup/word': '401 / 404 Not found',
  'PUT /api/lookup/word': '401 / 404 Not found',
  'DELETE /api/lookup/word': '401 / 404 Not found',
  'PROPFIND /api/lookup/word': '401 / 404 Not found',
  'MKCOL /api/lookup/word': '401 / 404 Not found',
  'OPTIONS /api/lookup/word': '404 Not found / 404 Not found',
  'GET /api/lookup/audio/file': '404 Not found / 404 Not found',
  'HEAD /api/lookup/audio/file': '404 / 404',
  'POST /api/lookup/audio/file': '401 / 405',
  'PUT /api/lookup/audio/file': '401 / 405',
  'DELETE /api/lookup/audio/file': '401 / 405',
  'PROPFIND /api/lookup/audio/file': '401 / 405',
  'MKCOL /api/lookup/audio/file': '401 / 405',
  'OPTIONS /api/lookup/audio/file': '405 / 405',
  'GET /api/lookup': '401 / 404 Not found',
  'HEAD /api/lookup': '401 / 404',
  'POST /api/lookup': '401 / 405',
  'DELETE /api/lookup': '401 / 404 Not found',
  'PROPFIND /api/lookup': '401 / 404 Not found',
  'OPTIONS /api/lookup': '200 / 200',
  'GET /api/mine': '401 / 405',
  'HEAD /api/mine': '401 / 405',
  'POST /api/mine': '401 / 400 Invalid JSON',
  'PUT /api/mine': '401 / 405',
  'DELETE /api/mine': '401 / 405',
  'PROPFIND /api/mine': '401 / 405',
  'MKCOL /api/mine': '401 / 405',
  'OPTIONS /api/mine': '405 / 405',
  'GET /api/mine/targets': '401 / 405',
  'HEAD /api/mine/targets': '401 / 405',
  'POST /api/mine/targets': '401 / 404 Mining targets unavailable',
  'PUT /api/mine/targets': '401 / 405',
  'DELETE /api/mine/targets': '401 / 405',
  'PROPFIND /api/mine/targets': '401 / 405',
  'MKCOL /api/mine/targets': '401 / 405',
  'OPTIONS /api/mine/targets': '405 / 405',
  'GET /api/mine/forward': '401 / 405',
  'HEAD /api/mine/forward': '401 / 405',
  'POST /api/mine/forward': '401 / 400 Invalid JSON',
  'PUT /api/mine/forward': '401 / 405',
  'DELETE /api/mine/forward': '401 / 405',
  'PROPFIND /api/mine/forward': '401 / 405',
  'MKCOL /api/mine/forward': '401 / 405',
  'OPTIONS /api/mine/forward': '405 / 405',
  'GET /api/mine/other': '401 / 404 Not found',
  'HEAD /api/mine/other': '401 / 404',
  'POST /api/mine/other': '401 / 405',
  'DELETE /api/mine/other': '401 / 404 Not found',
  'PROPFIND /api/mine/other': '401 / 404 Not found',
  'OPTIONS /api/mine/other': '200 / 200',
  'GET /api/anki/note-type/x': '401 / 405',
  'HEAD /api/anki/note-type/x': '401 / 405',
  'POST /api/anki/note-type/x': '401 / 400 Invalid JSON',
  'PUT /api/anki/note-type/x': '401 / 405',
  'DELETE /api/anki/note-type/x': '401 / 405',
  'PROPFIND /api/anki/note-type/x': '401 / 405',
  'MKCOL /api/anki/note-type/x': '401 / 405',
  'OPTIONS /api/anki/note-type/x': '405 / 405',
  'GET /api/anki/source/x': '401 / 405',
  'HEAD /api/anki/source/x': '401 / 405',
  'POST /api/anki/source/x': '401 / 404 Source editing unavailable',
  'PUT /api/anki/source/x': '401 / 405',
  'DELETE /api/anki/source/x': '401 / 405',
  'PROPFIND /api/anki/source/x': '401 / 405',
  'MKCOL /api/anki/source/x': '401 / 405',
  'OPTIONS /api/anki/source/x': '405 / 405',
  'GET /api/anki/media/dedup/x': '401 / 405',
  'HEAD /api/anki/media/dedup/x': '401 / 405',
  'POST /api/anki/media/dedup/x': '401 / 400 Invalid JSON',
  'PUT /api/anki/media/dedup/x': '401 / 405',
  'DELETE /api/anki/media/dedup/x': '401 / 405',
  'PROPFIND /api/anki/media/dedup/x': '401 / 405',
  'MKCOL /api/anki/media/dedup/x': '401 / 405',
  'OPTIONS /api/anki/media/dedup/x': '405 / 405',
  'GET /api/anki/other': '401 / 404 Not found',
  'HEAD /api/anki/other': '401 / 404',
  'POST /api/anki/other': '401 / 405',
  'DELETE /api/anki/other': '401 / 404 Not found',
  'PROPFIND /api/anki/other': '401 / 404 Not found',
  'OPTIONS /api/anki/other': '200 / 200',
  'GET /api/media/dictionary': '401 / 404 Media off',
  'HEAD /api/media/dictionary': '401 / 404',
  'POST /api/media/dictionary': '401 / 405',
  'PUT /api/media/dictionary': '401 / 405',
  'DELETE /api/media/dictionary': '401 / 405',
  'PROPFIND /api/media/dictionary': '401 / 405',
  'MKCOL /api/media/dictionary': '401 / 405',
  'OPTIONS /api/media/dictionary': '405 / 405',
  'GET /api/media/dictionary?dictionary=d&path=a.svg&key=bad':
      '401 / 404 Media off',
  'HEAD /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 404',
  'POST /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'PUT /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'DELETE /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'PROPFIND /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'MKCOL /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'OPTIONS /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '405 / 405',
  'GET /api/duplicate': '401 / 405',
  'HEAD /api/duplicate': '401 / 405',
  'POST /api/duplicate': '401 / 400 Invalid JSON',
  'PUT /api/duplicate': '401 / 405',
  'DELETE /api/duplicate': '401 / 405',
  'PROPFIND /api/duplicate': '401 / 405',
  'MKCOL /api/duplicate': '401 / 405',
  'OPTIONS /api/duplicate': '405 / 405',
  'GET /api/extension/status': '401 / 405',
  'HEAD /api/extension/status': '401 / 405',
  'POST /api/extension/status':
      '401 / 200 {"app":"fushi","ready":true,"port":<port>,"dictionaryMediaKe',
  'PUT /api/extension/status': '401 / 405',
  'DELETE /api/extension/status': '401 / 405',
  'PROPFIND /api/extension/status': '401 / 405',
  'MKCOL /api/extension/status': '401 / 405',
  'OPTIONS /api/extension/status': '405 / 405',
  'GET /api/ping':
      '200 {"app":"fushi","pairing":{"v2":true},"tls":{"enabled":false} / 200 {"app":"fushi","pairing":{"v2":true},"tls":{"enabled":false}',
  'HEAD /api/ping': '401 / 405',
  'POST /api/ping': '401 / 405',
  'PUT /api/ping': '401 / 405',
  'DELETE /api/ping': '401 / 405',
  'PROPFIND /api/ping': '401 / 405',
  'MKCOL /api/ping': '401 / 405',
  'OPTIONS /api/ping': '405 / 405',
  'GET /api/srs/changes': '401 / 200 {"token":<n>,"own":false}',
  'HEAD /api/srs/changes': '401 / 405',
  'POST /api/srs/changes': '401 / 405',
  'PUT /api/srs/changes': '401 / 405',
  'DELETE /api/srs/changes': '401 / 405',
  'PROPFIND /api/srs/changes': '401 / 405',
  'MKCOL /api/srs/changes': '401 / 405',
  'OPTIONS /api/srs/changes': '405 / 405',
  'GET /api/srs/sync-status': '401 / 200 {"joined":true}',
  'HEAD /api/srs/sync-status': '401 / 405',
  'POST /api/srs/sync-status': '401 / 405',
  'PUT /api/srs/sync-status': '401 / 405',
  'DELETE /api/srs/sync-status': '401 / 405',
  'PROPFIND /api/srs/sync-status': '401 / 405',
  'MKCOL /api/srs/sync-status': '401 / 405',
  'OPTIONS /api/srs/sync-status': '405 / 405',
  'GET /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'HEAD /api/srs/remote/review': '401 / 426',
  'POST /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'PUT /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'DELETE /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'PROPFIND /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'MKCOL /api/srs/remote/review': '401 / 426 {"error":"upgrade_required"}',
  'OPTIONS /api/srs/remote/review':
      '426 {"error":"upgrade_required"} / 426 {"error":"upgrade_required"}',
  'GET /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'HEAD /api/srs/remote2/review': '401 / 404',
  'POST /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'PUT /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'DELETE /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'PROPFIND /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'MKCOL /api/srs/remote2/review': '401 / 404 Unknown remote op',
  'OPTIONS /api/srs/remote2/review':
      '404 Unknown remote op / 404 Unknown remote op',
  'GET /api/srs/other': '401 / 404 Not found',
  'HEAD /api/srs/other': '401 / 404',
  'POST /api/srs/other': '401 / 405',
  'DELETE /api/srs/other': '401 / 404 Not found',
  'PROPFIND /api/srs/other': '401 / 404 Not found',
  'OPTIONS /api/srs/other': '200 / 200',
  'GET /api/ai/relay/providers': '401 / 405',
  'HEAD /api/ai/relay/providers': '401 / 405',
  'POST /api/ai/relay/providers': '401 / 500 Internal Server Error',
  'PUT /api/ai/relay/providers': '401 / 405',
  'DELETE /api/ai/relay/providers': '401 / 405',
  'PROPFIND /api/ai/relay/providers': '401 / 405',
  'MKCOL /api/ai/relay/providers': '401 / 405',
  'OPTIONS /api/ai/relay/providers': '405 / 405',
  'GET /api/ai/relay': '401 / 404 Not found',
  'HEAD /api/ai/relay': '401 / 404',
  'POST /api/ai/relay': '401 / 405',
  'DELETE /api/ai/relay': '401 / 404 Not found',
  'PROPFIND /api/ai/relay': '401 / 404 Not found',
  'OPTIONS /api/ai/relay': '200 / 200',
  'GET /api/capabilities':
      '401 / 200 {"srsChangesV1":true,"mangaChapterProgress":{"v":1},"lookup"',
  'HEAD /api/capabilities': '401 / 405',
  'POST /api/capabilities': '401 / 405',
  'PUT /api/capabilities': '401 / 405',
  'DELETE /api/capabilities': '401 / 405',
  'PROPFIND /api/capabilities': '401 / 405',
  'MKCOL /api/capabilities': '401 / 405',
  'OPTIONS /api/capabilities': '405 / 405',
  'GET /api/host/addresses':
      '401 / 200 {"hostId":"host-1","deviceName":"surface-host","addresses":[',
  'HEAD /api/host/addresses': '401 / 405',
  'POST /api/host/addresses': '401 / 405',
  'PUT /api/host/addresses': '401 / 405',
  'DELETE /api/host/addresses': '401 / 405',
  'PROPFIND /api/host/addresses': '401 / 405',
  'MKCOL /api/host/addresses': '401 / 405',
  'OPTIONS /api/host/addresses': '405 / 405',
  'GET /api/host/update': '401 / 403 {"error":"peer_token_required"}',
  'HEAD /api/host/update': '401 / 405',
  'POST /api/host/update': '401 / 403 {"error":"peer_token_required"}',
  'PUT /api/host/update': '401 / 405',
  'DELETE /api/host/update': '401 / 405',
  'PROPFIND /api/host/update': '401 / 405',
  'MKCOL /api/host/update': '401 / 405',
  'OPTIONS /api/host/update': '405 / 405',
  'GET /api/ocr/screen': '401 / 500 Internal Server Error',
  'HEAD /api/ocr/screen': '401 / 500',
  'POST /api/ocr/screen': '401 / 500 Internal Server Error',
  'PUT /api/ocr/screen': '401 / 500 Internal Server Error',
  'DELETE /api/ocr/screen': '401 / 500 Internal Server Error',
  'PROPFIND /api/ocr/screen': '401 / 500 Internal Server Error',
  'MKCOL /api/ocr/screen': '401 / 500 Internal Server Error',
  'OPTIONS /api/ocr/screen':
      '500 Internal Server Error / 500 Internal Server Error',
  'GET /api/ocr/job': '401 / 404 Manga OCR off',
  'HEAD /api/ocr/job': '401 / 404',
  'POST /api/ocr/job': '401 / 404 Manga OCR off',
  'PUT /api/ocr/job': '401 / 404 Manga OCR off',
  'DELETE /api/ocr/job': '401 / 404 Manga OCR off',
  'PROPFIND /api/ocr/job': '401 / 404 Manga OCR off',
  'MKCOL /api/ocr/job': '401 / 404 Manga OCR off',
  'OPTIONS /api/ocr/job': '404 Manga OCR off / 404 Manga OCR off',
  'GET /api/jobs': '401 / 404 Host jobs off',
  'HEAD /api/jobs': '401 / 404',
  'POST /api/jobs': '401 / 404 Host jobs off',
  'PUT /api/jobs': '401 / 404 Host jobs off',
  'DELETE /api/jobs': '401 / 404 Host jobs off',
  'PROPFIND /api/jobs': '401 / 404 Host jobs off',
  'MKCOL /api/jobs': '401 / 404 Host jobs off',
  'OPTIONS /api/jobs': '404 Host jobs off / 404 Host jobs off',
  'GET /api/downloads': '401 / 404 Host downloads off',
  'HEAD /api/downloads': '401 / 404',
  'POST /api/downloads': '401 / 404 Host downloads off',
  'PUT /api/downloads': '401 / 404 Host downloads off',
  'DELETE /api/downloads': '401 / 404 Host downloads off',
  'PROPFIND /api/downloads': '401 / 404 Host downloads off',
  'MKCOL /api/downloads': '401 / 404 Host downloads off',
  'OPTIONS /api/downloads': '404 Host downloads off / 404 Host downloads off',
  'GET /api/torrent-engine': '401 / 404 Host torrent engine off',
  'HEAD /api/torrent-engine': '401 / 404',
  'POST /api/torrent-engine': '401 / 404 Host torrent engine off',
  'PUT /api/torrent-engine': '401 / 404 Host torrent engine off',
  'DELETE /api/torrent-engine': '401 / 404 Host torrent engine off',
  'PROPFIND /api/torrent-engine': '401 / 404 Host torrent engine off',
  'MKCOL /api/torrent-engine': '401 / 404 Host torrent engine off',
  'OPTIONS /api/torrent-engine':
      '404 Host torrent engine off / 404 Host torrent engine off',
  'GET /api/subscriptions': '401 / 404 Host subscriptions off',
  'HEAD /api/subscriptions': '401 / 404',
  'POST /api/subscriptions': '401 / 404 Host subscriptions off',
  'PUT /api/subscriptions': '401 / 404 Host subscriptions off',
  'DELETE /api/subscriptions': '401 / 404 Host subscriptions off',
  'PROPFIND /api/subscriptions': '401 / 404 Host subscriptions off',
  'MKCOL /api/subscriptions': '401 / 404 Host subscriptions off',
  'OPTIONS /api/subscriptions':
      '404 Host subscriptions off / 404 Host subscriptions off',
  'GET /api/assistant': '401 / 404 Host assistant off',
  'HEAD /api/assistant': '401 / 404',
  'POST /api/assistant': '401 / 404 Host assistant off',
  'PUT /api/assistant': '401 / 404 Host assistant off',
  'DELETE /api/assistant': '401 / 404 Host assistant off',
  'PROPFIND /api/assistant': '401 / 404 Host assistant off',
  'MKCOL /api/assistant': '401 / 404 Host assistant off',
  'OPTIONS /api/assistant': '404 Host assistant off / 404 Host assistant off',
  'GET /api/library/manga-chapter-progress': '401 / 404 Not found',
  'HEAD /api/library/manga-chapter-progress': '401 / 404',
  'POST /api/library/manga-chapter-progress': '401 / 404 Not found',
  'PUT /api/library/manga-chapter-progress': '401 / 404 Not found',
  'DELETE /api/library/manga-chapter-progress': '401 / 404 Not found',
  'PROPFIND /api/library/manga-chapter-progress': '401 / 404 Not found',
  'MKCOL /api/library/manga-chapter-progress': '401 / 404 Not found',
  'OPTIONS /api/library/manga-chapter-progress':
      '404 Not found / 404 Not found',
  'GET /api/library/music': '401 / 404 Not found',
  'HEAD /api/library/music': '401 / 404',
  'POST /api/library/music': '401 / 405',
  'DELETE /api/library/music': '401 / 404 Not found',
  'PROPFIND /api/library/music': '401 / 404 Not found',
  'OPTIONS /api/library/music': '200 / 200',
  'GET /api/library/media/streamurl': '401 / 405',
  'HEAD /api/library/media/streamurl': '401 / 405',
  'POST /api/library/media/streamurl': '401 / 400 Invalid JSON',
  'PUT /api/library/media/streamurl': '401 / 405',
  'DELETE /api/library/media/streamurl': '401 / 405',
  'PROPFIND /api/library/media/streamurl': '401 / 405',
  'MKCOL /api/library/media/streamurl': '401 / 405',
  'OPTIONS /api/library/media/streamurl': '405 / 405',
  'GET /api/library/media/stream': '401 Missing token / 401 Missing token',
  'HEAD /api/library/media/stream': '401 / 401',
  'POST /api/library/media/stream': '401 / 405',
  'PUT /api/library/media/stream': '401 / 405',
  'DELETE /api/library/media/stream': '401 / 405',
  'PROPFIND /api/library/media/stream': '401 / 405',
  'MKCOL /api/library/media/stream': '401 / 405',
  'OPTIONS /api/library/media/stream': '405 / 405',
  'GET /api/library/media/stream?token=bad':
      '403 Invalid or expired token / 403 Invalid or expired token',
  'HEAD /api/library/media/stream?token=bad': '403 / 403',
  'POST /api/library/media/stream?token=bad': '401 / 405',
  'PUT /api/library/media/stream?token=bad': '401 / 405',
  'DELETE /api/library/media/stream?token=bad': '401 / 405',
  'PROPFIND /api/library/media/stream?token=bad': '401 / 405',
  'MKCOL /api/library/media/stream?token=bad': '401 / 405',
  'OPTIONS /api/library/media/stream?token=bad': '405 / 405',
  'GET /api/library/media/streamrelease': '401 / 405',
  'HEAD /api/library/media/streamrelease': '401 / 405',
  'POST /api/library/media/streamrelease': '401 / 400 Missing ticket',
  'PUT /api/library/media/streamrelease': '401 / 405',
  'DELETE /api/library/media/streamrelease': '401 / 405',
  'PROPFIND /api/library/media/streamrelease': '401 / 405',
  'MKCOL /api/library/media/streamrelease': '401 / 405',
  'OPTIONS /api/library/media/streamrelease': '405 / 405',
  'GET /api/library/dictionaries': '401 / 500 Internal Server Error',
  'HEAD /api/library/dictionaries': '401 / 405',
  'POST /api/library/dictionaries': '401 / 405',
  'PUT /api/library/dictionaries': '401 / 405',
  'DELETE /api/library/dictionaries': '401 / 405',
  'PROPFIND /api/library/dictionaries': '401 / 405',
  'MKCOL /api/library/dictionaries': '401 / 405',
  'OPTIONS /api/library/dictionaries': '405 / 405',
  'GET /api/library/dictionaries/d1': '401 / 500 Internal Server Error',
  'HEAD /api/library/dictionaries/d1': '401 / 405',
  'POST /api/library/dictionaries/d1': '401 / 405',
  'PUT /api/library/dictionaries/d1':
      '401 / 500 Import failed: UnimplementedError: Symbol("importDictionary"',
  'DELETE /api/library/dictionaries/d1': '401 / 500 Internal Server Error',
  'PROPFIND /api/library/dictionaries/d1': '401 / 405',
  'MKCOL /api/library/dictionaries/d1': '401 / 405',
  'OPTIONS /api/library/dictionaries/d1': '405 / 405',
  'GET /api/library/book-progress': '401 / 500 Internal Server Error',
  'HEAD /api/library/book-progress': '401 / 405',
  'POST /api/library/book-progress': '401 / 405',
  'PUT /api/library/book-progress': '401 / 405',
  'DELETE /api/library/book-progress': '401 / 405',
  'PROPFIND /api/library/book-progress': '401 / 405',
  'MKCOL /api/library/book-progress': '401 / 405',
  'OPTIONS /api/library/book-progress': '405 / 405',
  'GET /api/library/books': '401 / 500 Internal Server Error',
  'HEAD /api/library/books': '401 / 405',
  'POST /api/library/books': '401 / 405',
  'PUT /api/library/books': '401 / 405',
  'DELETE /api/library/books': '401 / 405',
  'PROPFIND /api/library/books': '401 / 405',
  'MKCOL /api/library/books': '401 / 405',
  'OPTIONS /api/library/books': '405 / 405',
  'GET /api/library/books/b1': '401 / 500 Internal Server Error',
  'HEAD /api/library/books/b1': '401 / 405',
  'POST /api/library/books/b1': '401 / 405',
  'PUT /api/library/books/b1':
      '401 / 500 Import failed: UnimplementedError: Symbol("importBook")',
  'DELETE /api/library/books/b1': '401 / 500 Internal Server Error',
  'PROPFIND /api/library/books/b1': '401 / 405',
  'MKCOL /api/library/books/b1': '401 / 405',
  'OPTIONS /api/library/books/b1': '405 / 405',
  'GET /api/library/manga': '401 / 404 Not found',
  'HEAD /api/library/manga': '401 / 404',
  'POST /api/library/manga': '401 / 405',
  'DELETE /api/library/manga': '401 / 404 Not found',
  'PROPFIND /api/library/manga': '401 / 404 Not found',
  'OPTIONS /api/library/manga': '200 / 200',
  'GET /api/library/manga/m1': '401 / 404 Unknown manga route',
  'HEAD /api/library/manga/m1': '401 / 405',
  'POST /api/library/manga/m1': '401 / 405',
  'PUT /api/library/manga/m1': '401 / 405',
  'DELETE /api/library/manga/m1': '401 / 405',
  'PROPFIND /api/library/manga/m1': '401 / 405',
  'MKCOL /api/library/manga/m1': '401 / 405',
  'OPTIONS /api/library/manga/m1': '405 / 405',
  'GET /api/library/localaudio': '401 / 500 Internal Server Error',
  'HEAD /api/library/localaudio': '401 / 405',
  'POST /api/library/localaudio': '401 / 405',
  'PUT /api/library/localaudio': '401 / 405',
  'DELETE /api/library/localaudio': '401 / 405',
  'PROPFIND /api/library/localaudio': '401 / 405',
  'MKCOL /api/library/localaudio': '401 / 405',
  'OPTIONS /api/library/localaudio': '405 / 405',
  'GET /api/library/localaudio/a1': '401 / 500 Internal Server Error',
  'HEAD /api/library/localaudio/a1': '401 / 405',
  'POST /api/library/localaudio/a1': '401 / 405',
  'PUT /api/library/localaudio/a1':
      '401 / 500 Import failed: UnimplementedError: Symbol("importLocalAudio"',
  'DELETE /api/library/localaudio/a1': '401 / 500 Internal Server Error',
  'PROPFIND /api/library/localaudio/a1': '401 / 405',
  'MKCOL /api/library/localaudio/a1': '401 / 405',
  'OPTIONS /api/library/localaudio/a1': '405 / 405',
  'GET /api/library/audiobooks': '401 / 500 Internal Server Error',
  'HEAD /api/library/audiobooks': '401 / 405',
  'POST /api/library/audiobooks': '401 / 405',
  'PUT /api/library/audiobooks': '401 / 405',
  'DELETE /api/library/audiobooks': '401 / 405',
  'PROPFIND /api/library/audiobooks': '401 / 405',
  'MKCOL /api/library/audiobooks': '401 / 405',
  'OPTIONS /api/library/audiobooks': '405 / 405',
  'GET /api/library/audiobooks/a1': '401 / 500 Internal Server Error',
  'HEAD /api/library/audiobooks/a1': '401 / 405',
  'POST /api/library/audiobooks/a1': '401 / 405',
  'PUT /api/library/audiobooks/a1':
      '401 / 500 Import failed: UnimplementedError: Symbol("importAudiobook")',
  'DELETE /api/library/audiobooks/a1': '401 / 500 Internal Server Error',
  'PROPFIND /api/library/audiobooks/a1': '401 / 405',
  'MKCOL /api/library/audiobooks/a1': '401 / 405',
  'OPTIONS /api/library/audiobooks/a1': '405 / 405',
  'GET /api/library/metadata': '401 / 500 Internal Server Error',
  'HEAD /api/library/metadata': '401 / 405',
  'POST /api/library/metadata': '401 / 405',
  'PUT /api/library/metadata': '401 / 400 Invalid JSON',
  'DELETE /api/library/metadata': '401 / 405',
  'PROPFIND /api/library/metadata': '401 / 405',
  'MKCOL /api/library/metadata': '401 / 405',
  'OPTIONS /api/library/metadata': '405 / 405',
  'GET /api/library/metadata/v1': '401 / 404 Not found',
  'HEAD /api/library/metadata/v1': '401 / 404',
  'POST /api/library/metadata/v1': '401 / 404 Not found',
  'PUT /api/library/metadata/v1': '401 / 404 Not found',
  'DELETE /api/library/metadata/v1': '401 / 404 Not found',
  'PROPFIND /api/library/metadata/v1': '401 / 404 Not found',
  'MKCOL /api/library/metadata/v1': '401 / 404 Not found',
  'OPTIONS /api/library/metadata/v1': '404 Not found / 404 Not found',
  'GET /api/library/videos': '401 / 500 Internal Server Error',
  'HEAD /api/library/videos': '401 / 405',
  'POST /api/library/videos': '401 / 405',
  'PUT /api/library/videos': '401 / 405',
  'DELETE /api/library/videos': '401 / 405',
  'PROPFIND /api/library/videos': '401 / 405',
  'MKCOL /api/library/videos': '401 / 405',
  'OPTIONS /api/library/videos': '405 / 405',
  'GET /api/library/videos/v1': '401 / 404 Not found',
  'HEAD /api/library/videos/v1': '401 / 404',
  'POST /api/library/videos/v1': '401 / 404 Not found',
  'PUT /api/library/videos/v1':
      '401 / 500 Video import failed: UnimplementedError: Symbol("importVideo',
  'DELETE /api/library/videos/v1':
      '401 / 500 Video delete failed: UnimplementedError: Symbol("deleteVideo',
  'PROPFIND /api/library/videos/v1': '401 / 404 Not found',
  'MKCOL /api/library/videos/v1': '401 / 404 Not found',
  'OPTIONS /api/library/videos/v1': '404 Not found / 404 Not found',
  'GET /api/library/videos/v1/streamurl': '401 / 500 Internal Server Error',
  'HEAD /api/library/videos/v1/streamurl': '401 / 405',
  'POST /api/library/videos/v1/streamurl': '401 / 405',
  'PUT /api/library/videos/v1/streamurl': '401 / 405',
  'DELETE /api/library/videos/v1/streamurl': '401 / 405',
  'PROPFIND /api/library/videos/v1/streamurl': '401 / 405',
  'MKCOL /api/library/videos/v1/streamurl': '401 / 405',
  'OPTIONS /api/library/videos/v1/streamurl': '405 / 405',
  'GET /api/library/videos/v1/stream': '401 Missing token / 401 Missing token',
  'HEAD /api/library/videos/v1/stream': '401 / 405',
  'POST /api/library/videos/v1/stream': '401 / 405',
  'PUT /api/library/videos/v1/stream': '401 / 405',
  'DELETE /api/library/videos/v1/stream': '401 / 405',
  'PROPFIND /api/library/videos/v1/stream': '401 / 405',
  'MKCOL /api/library/videos/v1/stream': '401 / 405',
  'OPTIONS /api/library/videos/v1/stream': '405 / 405',
  'GET /api/library/videos/v1/stream?token=bad':
      '403 Invalid or expired token / 403 Invalid or expired token',
  'HEAD /api/library/videos/v1/stream?token=bad': '401 / 405',
  'POST /api/library/videos/v1/stream?token=bad': '401 / 405',
  'PUT /api/library/videos/v1/stream?token=bad': '401 / 405',
  'DELETE /api/library/videos/v1/stream?token=bad': '401 / 405',
  'PROPFIND /api/library/videos/v1/stream?token=bad': '401 / 405',
  'MKCOL /api/library/videos/v1/stream?token=bad': '401 / 405',
  'OPTIONS /api/library/videos/v1/stream?token=bad': '405 / 405',
  'GET /api/library/videos/v1/hls.m3u8':
      '401 Missing token / 401 Missing token',
  'HEAD /api/library/videos/v1/hls.m3u8': '401 / 405',
  'POST /api/library/videos/v1/hls.m3u8': '401 / 405',
  'PUT /api/library/videos/v1/hls.m3u8': '401 / 405',
  'DELETE /api/library/videos/v1/hls.m3u8': '401 / 405',
  'PROPFIND /api/library/videos/v1/hls.m3u8': '401 / 405',
  'MKCOL /api/library/videos/v1/hls.m3u8': '401 / 405',
  'OPTIONS /api/library/videos/v1/hls.m3u8': '405 / 405',
  'GET /api/library/videos/v1/hlsseg.ts':
      '401 Missing token / 401 Missing token',
  'HEAD /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'POST /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'PUT /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'DELETE /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'PROPFIND /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'MKCOL /api/library/videos/v1/hlsseg.ts': '401 / 405',
  'OPTIONS /api/library/videos/v1/hlsseg.ts': '405 / 405',
  'GET /api/library/videos/v1/bdclip.m2ts':
      '401 Missing token / 401 Missing token',
  'HEAD /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'POST /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'PUT /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'DELETE /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'PROPFIND /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'MKCOL /api/library/videos/v1/bdclip.m2ts': '401 / 405',
  'OPTIONS /api/library/videos/v1/bdclip.m2ts': '405 / 405',
  'GET /api/library/videos/v1/sidecaraudio':
      '401 Missing token / 401 Missing token',
  'HEAD /api/library/videos/v1/sidecaraudio': '401 / 405',
  'POST /api/library/videos/v1/sidecaraudio': '401 / 405',
  'PUT /api/library/videos/v1/sidecaraudio': '401 / 405',
  'DELETE /api/library/videos/v1/sidecaraudio': '401 / 405',
  'PROPFIND /api/library/videos/v1/sidecaraudio': '401 / 405',
  'MKCOL /api/library/videos/v1/sidecaraudio': '401 / 405',
  'OPTIONS /api/library/videos/v1/sidecaraudio': '405 / 405',
  'GET /api/library/videos/v1/disc': '401 / 500 Internal Server Error',
  'HEAD /api/library/videos/v1/disc': '401 / 405',
  'POST /api/library/videos/v1/disc': '401 / 405',
  'PUT /api/library/videos/v1/disc': '401 / 405',
  'DELETE /api/library/videos/v1/disc': '401 / 405',
  'PROPFIND /api/library/videos/v1/disc': '401 / 405',
  'MKCOL /api/library/videos/v1/disc': '401 / 405',
  'OPTIONS /api/library/videos/v1/disc': '405 / 405',
  'GET /api/library/disc/t1/BDMV/index.bdmv':
      '401 Disc share session expired / 401 Disc share session expired',
  'HEAD /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'POST /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'PUT /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'DELETE /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'PROPFIND /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'MKCOL /api/library/disc/t1/BDMV/index.bdmv': '401 / 405',
  'OPTIONS /api/library/disc/t1/BDMV/index.bdmv': '405 / 405',
  'GET /api/library/disc': '401 / 404 Not found',
  'HEAD /api/library/disc': '401 / 404',
  'POST /api/library/disc': '401 / 405',
  'DELETE /api/library/disc': '401 / 404 Not found',
  'PROPFIND /api/library/disc': '401 / 404 Not found',
  'OPTIONS /api/library/disc': '200 / 200',
  'GET /api/library/aggregate': '401 / 500 Internal Server Error',
  'HEAD /api/library/aggregate': '401 / 405',
  'POST /api/library/aggregate': '401 / 405',
  'PUT /api/library/aggregate': '401 / 500 Internal Server Error',
  'DELETE /api/library/aggregate': '401 / 405',
  'PROPFIND /api/library/aggregate': '401 / 405',
  'MKCOL /api/library/aggregate': '401 / 405',
  'OPTIONS /api/library/aggregate': '405 / 405',
  'GET /api/library/activity': '401 / 500 Internal Server Error',
  'HEAD /api/library/activity': '401 / 405',
  'POST /api/library/activity': '401 / 405',
  'PUT /api/library/activity': '401 / 405',
  'DELETE /api/library/activity': '401 / 405',
  'PROPFIND /api/library/activity': '401 / 405',
  'MKCOL /api/library/activity': '401 / 405',
  'OPTIONS /api/library/activity': '405 / 405',
  'GET /api/library/collections': '401 / 500 Internal Server Error',
  'HEAD /api/library/collections': '401 / 405',
  'POST /api/library/collections': '401 / 400 Invalid JSON',
  'PUT /api/library/collections': '401 / 405',
  'DELETE /api/library/collections': '401 / 405',
  'PROPFIND /api/library/collections': '401 / 405',
  'MKCOL /api/library/collections': '401 / 405',
  'OPTIONS /api/library/collections': '405 / 405',
  'GET /api/library/tags': '401 / 500 Internal Server Error',
  'HEAD /api/library/tags': '401 / 405',
  'POST /api/library/tags': '401 / 400 Invalid JSON',
  'PUT /api/library/tags': '401 / 405',
  'DELETE /api/library/tags': '401 / 405',
  'PROPFIND /api/library/tags': '401 / 405',
  'MKCOL /api/library/tags': '401 / 405',
  'OPTIONS /api/library/tags': '405 / 405',
  'GET /api/library/media-links': '401 / 500 Internal Server Error',
  'HEAD /api/library/media-links': '401 / 405',
  'POST /api/library/media-links': '401 / 400 Invalid JSON',
  'PUT /api/library/media-links': '401 / 405',
  'DELETE /api/library/media-links': '401 / 405',
  'PROPFIND /api/library/media-links': '401 / 405',
  'MKCOL /api/library/media-links': '401 / 405',
  'OPTIONS /api/library/media-links': '405 / 405',
  'GET /api/library/online-items': '401 / 500 Internal Server Error',
  'HEAD /api/library/online-items': '401 / 405',
  'POST /api/library/online-items': '401 / 400 Invalid JSON',
  'PUT /api/library/online-items': '401 / 400 Invalid JSON',
  'DELETE /api/library/online-items': '401 / 405',
  'PROPFIND /api/library/online-items': '401 / 405',
  'MKCOL /api/library/online-items': '401 / 405',
  'OPTIONS /api/library/online-items': '405 / 405',
  'GET /api/library/other': '401 / 404 Not found',
  'HEAD /api/library/other': '401 / 404',
  'POST /api/library/other': '401 / 405',
  'DELETE /api/library/other': '401 / 404 Not found',
  'PROPFIND /api/library/other': '401 / 404 Not found',
  'OPTIONS /api/library/other': '200 / 200',
  'GET /api/interconnect/service-config':
      '401 / 403 HTTPS required for service config',
  'HEAD /api/interconnect/service-config': '401 / 405',
  'POST /api/interconnect/service-config': '401 / 405',
  'PUT /api/interconnect/service-config': '401 / 405',
  'DELETE /api/interconnect/service-config': '401 / 405',
  'PROPFIND /api/interconnect/service-config': '401 / 405',
  'MKCOL /api/interconnect/service-config': '401 / 405',
  'OPTIONS /api/interconnect/service-config': '405 / 405',
  'GET /api/interconnect/source-share': '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/source-share': '401 / 405',
  'POST /api/interconnect/source-share': '401 / 405',
  'PUT /api/interconnect/source-share': '401 / 405',
  'DELETE /api/interconnect/source-share': '401 / 405',
  'PROPFIND /api/interconnect/source-share': '401 / 405',
  'MKCOL /api/interconnect/source-share': '401 / 405',
  'OPTIONS /api/interconnect/source-share': '405 / 405',
  'GET /api/interconnect/source-share/package':
      '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/source-share/package': '401 / 405',
  'POST /api/interconnect/source-share/package': '401 / 405',
  'PUT /api/interconnect/source-share/package': '401 / 405',
  'DELETE /api/interconnect/source-share/package': '401 / 405',
  'PROPFIND /api/interconnect/source-share/package': '401 / 405',
  'MKCOL /api/interconnect/source-share/package': '401 / 405',
  'OPTIONS /api/interconnect/source-share/package': '405 / 405',
  'GET /api/interconnect/plugin-relay': '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/plugin-relay': '401 / 405',
  'POST /api/interconnect/plugin-relay': '401 / 405',
  'PUT /api/interconnect/plugin-relay': '401 / 405',
  'DELETE /api/interconnect/plugin-relay': '401 / 405',
  'PROPFIND /api/interconnect/plugin-relay': '401 / 405',
  'MKCOL /api/interconnect/plugin-relay': '401 / 405',
  'OPTIONS /api/interconnect/plugin-relay': '405 / 405',
  'GET /api/interconnect/plugin-relay/invoke': '401 / 405',
  'HEAD /api/interconnect/plugin-relay/invoke': '401 / 405',
  'POST /api/interconnect/plugin-relay/invoke':
      '401 / 403 {"error":"https_required"}',
  'PUT /api/interconnect/plugin-relay/invoke': '401 / 405',
  'DELETE /api/interconnect/plugin-relay/invoke': '401 / 405',
  'PROPFIND /api/interconnect/plugin-relay/invoke': '401 / 405',
  'MKCOL /api/interconnect/plugin-relay/invoke': '401 / 405',
  'OPTIONS /api/interconnect/plugin-relay/invoke': '405 / 405',
  'GET /api/interconnect/plugin-relay/stream/t1':
      '404 Unknown stream ticket / 404 Unknown stream ticket',
  'HEAD /api/interconnect/plugin-relay/stream/t1': '404 / 404',
  'POST /api/interconnect/plugin-relay/stream/t1': '401 / 405',
  'PUT /api/interconnect/plugin-relay/stream/t1': '401 / 405',
  'DELETE /api/interconnect/plugin-relay/stream/t1': '401 / 405',
  'PROPFIND /api/interconnect/plugin-relay/stream/t1': '401 / 405',
  'MKCOL /api/interconnect/plugin-relay/stream/t1': '401 / 405',
  'OPTIONS /api/interconnect/plugin-relay/stream/t1': '405 / 405',
  'GET /api/interconnect/plugin-relay/stream/':
      '401 / 404 Unknown stream ticket',
  'HEAD /api/interconnect/plugin-relay/stream/': '401 / 404',
  'POST /api/interconnect/plugin-relay/stream/': '401 / 405',
  'DELETE /api/interconnect/plugin-relay/stream/': '401 / 405',
  'PROPFIND /api/interconnect/plugin-relay/stream/': '401 / 405',
  'OPTIONS /api/interconnect/plugin-relay/stream/': '405 / 405',
  'GET /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/profile': '401 / 405',
  'POST /api/interconnect/profile': '401 / 405',
  'PUT /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'DELETE /api/interconnect/profile': '401 / 405',
  'PROPFIND /api/interconnect/profile': '401 / 405',
  'MKCOL /api/interconnect/profile': '401 / 405',
  'OPTIONS /api/interconnect/profile': '405 / 405',
  'GET /api/interconnect/leaderboard-link': '401 / 405',
  'HEAD /api/interconnect/leaderboard-link': '401 / 405',
  'POST /api/interconnect/leaderboard-link':
      '401 / 403 {"error":"https_required"}',
  'PUT /api/interconnect/leaderboard-link': '401 / 405',
  'DELETE /api/interconnect/leaderboard-link': '401 / 405',
  'PROPFIND /api/interconnect/leaderboard-link': '401 / 405',
  'MKCOL /api/interconnect/leaderboard-link': '401 / 405',
  'OPTIONS /api/interconnect/leaderboard-link': '405 / 405',
  'GET /api/interconnect/other': '401 / 404 Not found',
  'HEAD /api/interconnect/other': '401 / 404',
  'POST /api/interconnect/other': '401 / 405',
  'DELETE /api/interconnect/other': '401 / 404 Not found',
  'PROPFIND /api/interconnect/other': '401 / 404 Not found',
  'OPTIONS /api/interconnect/other': '200 / 200',
  'GET /api/tombstones': '401 / 500 Internal Server Error',
  'HEAD /api/tombstones': '401 / 405',
  'POST /api/tombstones': '401 / 405',
  'PUT /api/tombstones': '401 / 405',
  'DELETE /api/tombstones': '401 / 405',
  'PROPFIND /api/tombstones': '401 / 405',
  'MKCOL /api/tombstones': '401 / 405',
  'OPTIONS /api/tombstones': '405 / 405',
  'GET /api/unknown': '401 / 404 Not found',
  'HEAD /api/unknown': '401 / 404',
  'POST /api/unknown': '401 / 405',
  'DELETE /api/unknown': '401 / 404 Not found',
  'PROPFIND /api/unknown': '401 / 404 Not found',
  'OPTIONS /api/unknown': '200 / 200',
};

/// 对照表探测的端点：每条路由至少一条代表路径，外加紧贴路由边界、应掉进 WebDAV 树的路径。
const List<String> _kProbePaths = <String>[
  '/api/pair',
  '/api/pair/v2',
  '/api/pair/v2/confirm',
  '/api/pair/other',
  '/api/game-stream/sessions',
  '/api/game-stream/sessions/s1',
  '/api/game-stream/join',
  '/api/game-stream/signal',
  '/api/game-stream/stop',
  '/api/game-stream/mine',
  '/api/game-stream/library',
  '/api/game-stream/library/cover',
  '/api/game-stream/launch',
  '/api/game-stream/launch/status',
  '/api/game-stream/other',
  '/api/video-remote/play',
  '/api/video-remote/nope',
  '/api/video-remote',
  '/api/lookup/word',
  '/api/lookup/audio/file',
  '/api/lookup',
  '/api/mine',
  '/api/mine/targets',
  '/api/mine/forward',
  '/api/mine/other',
  '/api/anki/note-type/x',
  '/api/anki/source/x',
  '/api/anki/media/dedup/x',
  '/api/anki/other',
  '/api/media/dictionary',
  '/api/media/dictionary?dictionary=d&path=a.svg&key=bad',
  '/api/duplicate',
  '/api/extension/status',
  '/api/ping',
  '/api/srs/changes',
  '/api/srs/sync-status',
  '/api/srs/remote/review',
  '/api/srs/remote2/review',
  '/api/srs/other',
  '/api/ai/relay/providers',
  '/api/ai/relay',
  '/api/capabilities',
  '/api/host/addresses',
  '/api/host/update',
  '/api/ocr/screen',
  '/api/ocr/job',
  '/api/jobs',
  '/api/downloads',
  '/api/torrent-engine',
  '/api/subscriptions',
  '/api/assistant',
  '/api/library/manga-chapter-progress',
  '/api/library/music',
  '/api/library/media/streamurl',
  '/api/library/media/stream',
  '/api/library/media/stream?token=bad',
  '/api/library/media/streamrelease',
  '/api/library/dictionaries',
  '/api/library/dictionaries/d1',
  '/api/library/book-progress',
  '/api/library/books',
  '/api/library/books/b1',
  '/api/library/manga',
  '/api/library/manga/m1',
  '/api/library/localaudio',
  '/api/library/localaudio/a1',
  '/api/library/audiobooks',
  '/api/library/audiobooks/a1',
  '/api/library/metadata',
  '/api/library/metadata/v1',
  '/api/library/videos',
  '/api/library/videos/v1',
  '/api/library/videos/v1/streamurl',
  '/api/library/videos/v1/stream',
  '/api/library/videos/v1/stream?token=bad',
  '/api/library/videos/v1/hls.m3u8',
  '/api/library/videos/v1/hlsseg.ts',
  '/api/library/videos/v1/bdclip.m2ts',
  '/api/library/videos/v1/sidecaraudio',
  '/api/library/videos/v1/disc',
  '/api/library/disc/t1/BDMV/index.bdmv',
  '/api/library/disc',
  '/api/library/aggregate',
  '/api/library/activity',
  '/api/library/collections',
  '/api/library/tags',
  '/api/library/media-links',
  '/api/library/online-items',
  '/api/library/other',
  '/api/interconnect/service-config',
  '/api/interconnect/source-share',
  '/api/interconnect/source-share/package',
  '/api/interconnect/plugin-relay',
  '/api/interconnect/plugin-relay/invoke',
  '/api/interconnect/plugin-relay/stream/t1',
  '/api/interconnect/plugin-relay/stream/',
  '/api/interconnect/profile',
  '/api/interconnect/leaderboard-link',
  '/api/interconnect/other',
  '/api/tombstones',
  '/api/unknown',
];

/// 对照表探测的方法。PUT / MKCOL 只探 `/api/` 下已知路由，不往 WebDAV 树里写东西（见 [_writesIntoDav]）。
const List<String> _kProbeMethods = <String>[
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'DELETE',
  'PROPFIND',
  'MKCOL',
  'OPTIONS',
];

class _Library extends FushiLibraryHostService
    implements
        MangaLibraryHost,
        VideoMetadataHost,
        TagSyncHost,
        PdfBookImportHost,
        MediaLinkSyncHost,
        OnlineLibrarySyncHost,
        StreamVideoSyncHost,
        DeletionTombstoneHost,
        VideoDeletionHost,
        VideoSubtitleDefaultHost,
        VideoSubtitleClearHost,
        VideoSidecarSubtitleListHost,
        VideoSidecarAudioListHost,
        VideoDiscShareHost,
        VideoClipExportHost,
        VideoDiscTitleAudioHost,
        VideoMetadataOrderingHost,
        InterconnectServiceConfigHost,
        InterconnectProfileHost,
        MangaChapterProgressHost,
        BookProgressBatchHost {
  @override
  bool get acceptsPdfBooks => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Lookup implements FushiRemoteLookupService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Mining implements FushiRemoteMiningService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _History implements FushiRemoteHistoryService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _GameStream implements FushiRemoteGameStreamService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _VideoRemote implements VideoRemoteService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Updater implements HostSelfUpdater {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Leaderboard implements InterconnectLeaderboardLinkHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SourceShare implements InterconnectSourceShareHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _PluginRelay implements InterconnectPluginRelayHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SrsReview implements SrsRemoteStoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _AiSettings implements AiSettingsSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ScreenOcr implements ScreenOcrHost {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 每个能力位取最满一态的 host。[tls] = 是否带 [SecurityContext]（只影响 TLS 相关位；带了就不能
/// 明文起监听，只走 [FushiSyncServer.handleInProcess]）。
FushiSyncServer _maximalServer(String dir, {required bool tls}) {
  final FushiSyncServer server = FushiSyncServer(
    syncDataDir: dir,
    port: 0,
    token: _token,
    remoteLookupService: _Lookup(),
    miningService: _Mining(),
    historyService: _History(),
    libraryService: _Library(),
    screenOcr: _ScreenOcr(),
    gameStreamService: _GameStream(),
    videoRemoteService: _VideoRemote(),
    securityContext: tls ? SecurityContext() : null,
    hostFingerprint: tls ? 'aa:bb' : null,
    deviceName: 'surface-host',
  );
  server
    ..hostId = 'host-1'
    ..hostSelfUpdater = _Updater()
    ..leaderboardLinkHost = _Leaderboard()
    ..sourceShareHost = _SourceShare()
    ..pluginRelayHost = _PluginRelay()
    ..srsRemoteStoreProvider = (() => _SrsReview())
    ..aiRelaySettings = (() => _AiSettings())
    ..srsSync2Joined = (() => true)
    ..videoSubtitleBackfill = ((String id, {String? language}) async => null)
    ..graphicSubtitleTrackExporter =
        (({
          required String videoPath,
          required int streamIndex,
          required String codec,
        }) async => null);
  return server;
}

Future<String> _capabilitiesInProcess(FushiSyncServer server) async {
  final shelf.Response res = await server.handleInProcess(
    shelf.Request('GET', Uri.parse('http://127.0.0.1/api/capabilities')),
  );
  expect(res.statusCode, 200);
  return res.readAsString();
}

String _basic(String password) =>
    'Basic ${base64Encode(utf8.encode('surface:$password'))}';

/// 发一个请求，回 `状态码 体`（体截 60 字符，空白压成一个空格；本次监听的端口号换成 `<port>`、
/// 复习长轮询令牌换成 `<n>`）。
Future<String> _probe(
  FushiSyncServer server,
  String method,
  String pathAndQuery, {
  String? password,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery'),
    );
    if (password != null) req.headers.set('authorization', _basic(password));
    final HttpClientResponse res = await req.close();
    final List<int> bytes = <int>[
      for (final List<int> chunk in await res.toList()) ...chunk,
    ];
    String body = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('${server.port}', '<port>')
        // 长轮询令牌每次启动都不同。
        .replaceAll(RegExp(r'"token":\d+'), '"token":<n>');
    if (body.length > 60) body = body.substring(0, 60);
    return '${res.statusCode} $body'.trimRight();
  } finally {
    client.close(force: true);
  }
}

/// PUT / MKCOL 到不归任何路由的路径会在 WebDAV 树里落文件 / 建目录；对照表不这么探。
bool _writesIntoDav(String method, String path) =>
    (method == 'PUT' || method == 'MKCOL') &&
    (path.endsWith('/other') ||
        path == '/api/unknown' ||
        path == '/api/video-remote' ||
        path == '/api/lookup' ||
        path == '/api/ai/relay' ||
        path == '/api/library/manga' ||
        path == '/api/library/disc' ||
        // 音乐模块只在 app / 服务端经 `modules` 注入；裸 host 上这条前缀今天落进 WebDAV 树。
        path == '/api/library/music' ||
        path == '/api/interconnect/plugin-relay/stream/');

Iterable<(String, String)> _probeKeys() sync* {
  for (final String path in _kProbePaths) {
    for (final String method in _kProbeMethods) {
      if (_writesIntoDav(method, path)) continue;
      yield (method, path);
    }
  }
}

/// `FUSHI_SURFACE_DUMP=1` 时把实测值打印出来（只在有意改对外面时用来重录期望值）。
final bool _dump = Platform.environment['FUSHI_SURFACE_DUMP'] == '1';

void _report(String name, Object actual) {
  if (!_dump) return;
  // ignore: avoid_print
  print('=== $name\n${actual is String ? actual : jsonEncode(actual)}');
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('interconnect_surface_');
    setTranscodeAvailableForTesting(true);
  });

  tearDown(() async {
    setTranscodeAvailableForTesting(null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('什么都没接：能力表逐字节不变', () async {
    final String body = await _capabilitiesInProcess(
      FushiSyncServer(syncDataDir: tmp.path, port: 0, token: _token),
    );
    _report('minimal capabilities', body);
    expect(body, _kMinimalCapabilitiesJson);
  });

  test('每个能力位最满一态：能力表逐字节不变', () async {
    final String body = await _capabilitiesInProcess(
      _maximalServer(tmp.path, tls: true),
    );
    _report('maximal capabilities', body);
    expect(body, _kMaximalCapabilitiesJson);
  });

  test('功能全关：各类端点的鉴权与状态码不变', () async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
    );
    await server.start();
    addTearDown(server.stop);
    final Map<String, String> actual = <String, String>{};
    for (final (String method, String path) in _probeKeys()) {
      final String anonymous = await _probe(server, method, path);
      final String host = await _probe(server, method, path, password: _token);
      actual['$method $path'] = '$anonymous / $host';
    }
    _report('minimal surface', actual);
    expect(actual, _kMinimalSurface);
    // 功能关着的路由一律被占住，WebDAV 树里不会因此长出 `api/` 目录。
    expect(
      Directory('${tmp.path}/sync-data/api/library').existsSync(),
      isFalse,
    );
  });

  test('功能全接：各类端点的鉴权与状态码不变', () async {
    final FushiSyncServer server = _maximalServer(tmp.path, tls: false);
    await server.start();
    addTearDown(server.stop);
    final Map<String, String> actual = <String, String>{};
    for (final (String method, String path) in _probeKeys()) {
      final String anonymous = await _probe(server, method, path);
      final String host = await _probe(server, method, path, password: _token);
      actual['$method $path'] = '$anonymous / $host';
    }
    _report('featured surface', actual);
    expect(actual, _kFeaturedSurface);
  });
}
