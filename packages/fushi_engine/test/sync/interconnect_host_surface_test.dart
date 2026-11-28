/// 互联 host 的对外面快照（架构重构 A1 的前置护栏，docs/specs/2026-11-28-architecture-redesign.md）：
///
/// 1. `/api/capabilities` **整张表**逐字节快照，两种装配各一份：什么都没接（[_kMinimalCapabilitiesJson]），
///    以及每个能力位都取「最满」那一态（[_kMaximalCapabilitiesJson]）。能力位从手拼 Map 迁到模块表时，键序、
///    「false」与「缺键」两种形态都靠这两份钉住。
/// 2. 端点对照表：每类端点在「没带凭据 / 带 host 凭据」下的状态码与错误体（[_kMinimalSurface] 是功能全关，
///    [_kFeaturedSurface] 是功能全接、不带凭据）。钉住的是鉴权豁免（哪些方法免 Basic）、功能关着回 404 而
///    不掉进 WebDAV 树、方法不对回 405、以及各门的先后。
///
/// 期望值是迁移前（develop 4d853cf791）的服务器原样吐出的；迁移只许让它们保持不变。
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
  'GET /api/pair/v2': '401 / 405',
  'HEAD /api/pair/v2': '401 / 405',
  'POST /api/pair/v2':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2': '401 / 405',
  'GET /api/pair/v2/confirm': '401 / 405',
  'HEAD /api/pair/v2/confirm': '401 / 405',
  'POST /api/pair/v2/confirm':
      '403 {"reason":"unavailable"} / 403 {"reason":"unavailable"}',
  'PUT /api/pair/v2/confirm': '401 / 405',
  'GET /api/pair/other': '401 / 404 Not found',
  'HEAD /api/pair/other': '401 / 404',
  'POST /api/pair/other': '401 / 405',
  'GET /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/sessions': '401 / 404',
  'POST /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/sessions':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/sessions/s1': '401 / 404',
  'POST /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/sessions/s1':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/join': '401 / 404',
  'POST /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/join':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/signal': '401 / 404',
  'POST /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/signal':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/stop': '401 / 404',
  'POST /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/stop':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/mine': '401 / 404',
  'POST /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/mine':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/library': '401 / 404',
  'POST /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/library':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/library/cover': '401 / 404',
  'POST /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/library/cover':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/launch': '401 / 404',
  'POST /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/launch':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'HEAD /api/game-stream/launch/status': '401 / 404',
  'POST /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'PUT /api/game-stream/launch/status':
      '401 / 404 {"version":1,"code":"game_stream_off","error":"Game stream o',
  'GET /api/game-stream/other': '401 / 404 Not found',
  'HEAD /api/game-stream/other': '401 / 404',
  'POST /api/game-stream/other': '401 / 405',
  'GET /api/video-remote/play': '401 / 405',
  'HEAD /api/video-remote/play': '401 / 405',
  'POST /api/video-remote/play': '401 / 404 Video remote off',
  'PUT /api/video-remote/play': '401 / 405',
  'GET /api/video-remote/nope': '401 / 405',
  'HEAD /api/video-remote/nope': '401 / 405',
  'POST /api/video-remote/nope': '401 / 404 Video remote off',
  'PUT /api/video-remote/nope': '401 / 405',
  'GET /api/video-remote': '401 / 404 Not found',
  'HEAD /api/video-remote': '401 / 404',
  'POST /api/video-remote': '401 / 405',
  'GET /api/lookup/word': '401 / 404 Not found',
  'HEAD /api/lookup/word': '401 / 404',
  'POST /api/lookup/word': '401 / 404 Not found',
  'PUT /api/lookup/word': '401 / 404 Not found',
  'GET /api/lookup/audio/file': '404 Not found / 404 Not found',
  'HEAD /api/lookup/audio/file': '404 / 404',
  'POST /api/lookup/audio/file': '401 / 405',
  'PUT /api/lookup/audio/file': '401 / 405',
  'GET /api/lookup': '401 / 404 Not found',
  'HEAD /api/lookup': '401 / 404',
  'POST /api/lookup': '401 / 405',
  'GET /api/mine': '401 / 405',
  'HEAD /api/mine': '401 / 405',
  'POST /api/mine': '401 / 404 Mining off',
  'PUT /api/mine': '401 / 405',
  'GET /api/mine/targets': '401 / 405',
  'HEAD /api/mine/targets': '401 / 405',
  'POST /api/mine/targets': '401 / 404 Mining targets unavailable',
  'PUT /api/mine/targets': '401 / 405',
  'GET /api/mine/forward': '401 / 405',
  'HEAD /api/mine/forward': '401 / 405',
  'POST /api/mine/forward': '401 / 404 Mining off',
  'PUT /api/mine/forward': '401 / 405',
  'GET /api/mine/other': '401 / 404 Not found',
  'HEAD /api/mine/other': '401 / 404',
  'POST /api/mine/other': '401 / 405',
  'GET /api/anki/note-type/x': '401 / 405',
  'HEAD /api/anki/note-type/x': '401 / 405',
  'POST /api/anki/note-type/x': '401 / 404 Mining off',
  'PUT /api/anki/note-type/x': '401 / 405',
  'GET /api/anki/source/x': '401 / 405',
  'HEAD /api/anki/source/x': '401 / 405',
  'POST /api/anki/source/x': '401 / 404 Source editing unavailable',
  'PUT /api/anki/source/x': '401 / 405',
  'GET /api/anki/media/dedup/x': '401 / 405',
  'HEAD /api/anki/media/dedup/x': '401 / 405',
  'POST /api/anki/media/dedup/x': '401 / 404 Mining off',
  'PUT /api/anki/media/dedup/x': '401 / 405',
  'GET /api/anki/other': '401 / 404 Not found',
  'HEAD /api/anki/other': '401 / 404',
  'POST /api/anki/other': '401 / 405',
  'GET /api/media/dictionary': '401 / 404 Media off',
  'HEAD /api/media/dictionary': '401 / 404',
  'POST /api/media/dictionary': '401 / 405',
  'PUT /api/media/dictionary': '401 / 405',
  'GET /api/media/dictionary?dictionary=d&path=a.svg&key=bad':
      '401 / 404 Media off',
  'HEAD /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 404',
  'POST /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'PUT /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401 / 405',
  'GET /api/duplicate': '401 / 405',
  'HEAD /api/duplicate': '401 / 405',
  'POST /api/duplicate': '401 / 400 Invalid JSON',
  'PUT /api/duplicate': '401 / 405',
  'GET /api/extension/status': '401 / 405',
  'HEAD /api/extension/status': '401 / 405',
  'POST /api/extension/status': '401 / 200',
  'PUT /api/extension/status': '401 / 405',
  'GET /api/ping': '200 / 200',
  'HEAD /api/ping': '401 / 405',
  'POST /api/ping': '401 / 405',
  'PUT /api/ping': '401 / 405',
  'GET /api/srs/changes': '401 / 200',
  'HEAD /api/srs/changes': '401 / 405',
  'POST /api/srs/changes': '401 / 405',
  'PUT /api/srs/changes': '401 / 405',
  'GET /api/srs/sync-status': '401 / 404 SRS sync status not reported',
  'HEAD /api/srs/sync-status': '401 / 405',
  'POST /api/srs/sync-status': '401 / 405',
  'PUT /api/srs/sync-status': '401 / 405',
  'GET /api/srs/remote/review': '401 / 404 SRS review off',
  'HEAD /api/srs/remote/review': '401 / 404',
  'POST /api/srs/remote/review': '401 / 404 SRS review off',
  'PUT /api/srs/remote/review': '401 / 404 SRS review off',
  'GET /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'HEAD /api/srs/remote2/review': '401 / 503',
  'POST /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'PUT /api/srs/remote2/review': '401 / 503 {"error":"unavailable"}',
  'GET /api/srs/other': '401 / 404 Not found',
  'HEAD /api/srs/other': '401 / 404',
  'POST /api/srs/other': '401 / 405',
  'GET /api/ai/relay/providers': '401 / 404 AI relay off',
  'HEAD /api/ai/relay/providers': '401 / 404',
  'POST /api/ai/relay/providers': '401 / 404 AI relay off',
  'PUT /api/ai/relay/providers': '401 / 404 AI relay off',
  'GET /api/ai/relay': '401 / 404 Not found',
  'HEAD /api/ai/relay': '401 / 404',
  'POST /api/ai/relay': '401 / 405',
  'GET /api/capabilities': '401 / 200',
  'HEAD /api/capabilities': '401 / 405',
  'POST /api/capabilities': '401 / 405',
  'PUT /api/capabilities': '401 / 405',
  'GET /api/host/addresses': '401 / 404 No host id',
  'HEAD /api/host/addresses': '401 / 405',
  'POST /api/host/addresses': '401 / 405',
  'PUT /api/host/addresses': '401 / 405',
  'GET /api/host/update': '401 / 404 Host update off',
  'HEAD /api/host/update': '401 / 405',
  'POST /api/host/update': '401 / 404 Host update off',
  'PUT /api/host/update': '401 / 405',
  'GET /api/ocr/screen': '401 / 404 Screen OCR off',
  'HEAD /api/ocr/screen': '401 / 404',
  'POST /api/ocr/screen': '401 / 404 Screen OCR off',
  'PUT /api/ocr/screen': '401 / 404 Screen OCR off',
  'GET /api/ocr/job': '401 / 404 Manga OCR off',
  'HEAD /api/ocr/job': '401 / 404',
  'POST /api/ocr/job': '401 / 404 Manga OCR off',
  'PUT /api/ocr/job': '401 / 404 Manga OCR off',
  'GET /api/jobs': '401 / 404 Host jobs off',
  'HEAD /api/jobs': '401 / 404',
  'POST /api/jobs': '401 / 404 Host jobs off',
  'PUT /api/jobs': '401 / 404 Host jobs off',
  'GET /api/downloads': '401 / 404 Host downloads off',
  'HEAD /api/downloads': '401 / 404',
  'POST /api/downloads': '401 / 404 Host downloads off',
  'PUT /api/downloads': '401 / 404 Host downloads off',
  'GET /api/torrent-engine': '401 / 404 Host torrent engine off',
  'HEAD /api/torrent-engine': '401 / 404',
  'POST /api/torrent-engine': '401 / 404 Host torrent engine off',
  'PUT /api/torrent-engine': '401 / 404 Host torrent engine off',
  'GET /api/subscriptions': '401 / 404 Host subscriptions off',
  'HEAD /api/subscriptions': '401 / 404',
  'POST /api/subscriptions': '401 / 404 Host subscriptions off',
  'PUT /api/subscriptions': '401 / 404 Host subscriptions off',
  'GET /api/assistant': '401 / 404 Host assistant off',
  'HEAD /api/assistant': '401 / 404',
  'POST /api/assistant': '401 / 404 Host assistant off',
  'PUT /api/assistant': '401 / 404 Host assistant off',
  'GET /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'HEAD /api/library/manga-chapter-progress': '401 / 404',
  'POST /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'PUT /api/library/manga-chapter-progress':
      '401 / 404 Manga chapter progress unsupported',
  'GET /api/library/music': '401 / 404 Not found',
  'HEAD /api/library/music': '401 / 404',
  'POST /api/library/music': '401 / 405',
  'GET /api/library/media/streamurl': '401 / 405',
  'HEAD /api/library/media/streamurl': '401 / 405',
  'POST /api/library/media/streamurl': '401 / 400 Invalid JSON',
  'PUT /api/library/media/streamurl': '401 / 405',
  'GET /api/library/media/stream': '401 Missing token / 401 Missing token',
  'HEAD /api/library/media/stream': '401 / 401',
  'POST /api/library/media/stream': '401 / 405',
  'PUT /api/library/media/stream': '401 / 405',
  'GET /api/library/media/stream?token=bad':
      '403 Invalid or expired token / 403 Invalid or expired token',
  'HEAD /api/library/media/stream?token=bad': '403 / 403',
  'POST /api/library/media/stream?token=bad': '401 / 405',
  'PUT /api/library/media/stream?token=bad': '401 / 405',
  'GET /api/library/media/streamrelease': '401 / 405',
  'HEAD /api/library/media/streamrelease': '401 / 405',
  'POST /api/library/media/streamrelease': '401 / 400 Missing ticket',
  'PUT /api/library/media/streamrelease': '401 / 405',
  'GET /api/library/dictionaries': '401 / 404 Library service off',
  'HEAD /api/library/dictionaries': '401 / 404',
  'POST /api/library/dictionaries': '401 / 404 Library service off',
  'PUT /api/library/dictionaries': '401 / 404 Library service off',
  'GET /api/library/dictionaries/d1': '401 / 404 Library service off',
  'HEAD /api/library/dictionaries/d1': '401 / 404',
  'POST /api/library/dictionaries/d1': '401 / 404 Library service off',
  'PUT /api/library/dictionaries/d1': '401 / 404 Library service off',
  'GET /api/library/book-progress': '401 / 404 Book progress batch unsupported',
  'HEAD /api/library/book-progress': '401 / 404',
  'POST /api/library/book-progress':
      '401 / 404 Book progress batch unsupported',
  'PUT /api/library/book-progress': '401 / 404 Book progress batch unsupported',
  'GET /api/library/books': '401 / 404 Library service off',
  'HEAD /api/library/books': '401 / 404',
  'POST /api/library/books': '401 / 404 Library service off',
  'PUT /api/library/books': '401 / 404 Library service off',
  'GET /api/library/books/b1': '401 / 404 Library service off',
  'HEAD /api/library/books/b1': '401 / 404',
  'POST /api/library/books/b1': '401 / 404 Library service off',
  'PUT /api/library/books/b1': '401 / 404 Library service off',
  'GET /api/library/manga': '401 / 404 Not found',
  'HEAD /api/library/manga': '401 / 404',
  'POST /api/library/manga': '401 / 405',
  'GET /api/library/manga/m1': '401 / 404 Library service off',
  'HEAD /api/library/manga/m1': '401 / 404',
  'POST /api/library/manga/m1': '401 / 404 Library service off',
  'PUT /api/library/manga/m1': '401 / 404 Library service off',
  'GET /api/library/localaudio': '401 / 404 Library service off',
  'HEAD /api/library/localaudio': '401 / 404',
  'POST /api/library/localaudio': '401 / 404 Library service off',
  'PUT /api/library/localaudio': '401 / 404 Library service off',
  'GET /api/library/localaudio/a1': '401 / 404 Library service off',
  'HEAD /api/library/localaudio/a1': '401 / 404',
  'POST /api/library/localaudio/a1': '401 / 404 Library service off',
  'PUT /api/library/localaudio/a1': '401 / 404 Library service off',
  'GET /api/library/audiobooks': '401 / 404 Library service off',
  'HEAD /api/library/audiobooks': '401 / 404',
  'POST /api/library/audiobooks': '401 / 404 Library service off',
  'PUT /api/library/audiobooks': '401 / 404 Library service off',
  'GET /api/library/audiobooks/a1': '401 / 404 Library service off',
  'HEAD /api/library/audiobooks/a1': '401 / 404',
  'POST /api/library/audiobooks/a1': '401 / 404 Library service off',
  'PUT /api/library/audiobooks/a1': '401 / 404 Library service off',
  'GET /api/library/metadata': '401 / 404 Video metadata host off',
  'HEAD /api/library/metadata': '401 / 404',
  'POST /api/library/metadata': '401 / 404 Video metadata host off',
  'PUT /api/library/metadata': '401 / 404 Video metadata host off',
  'GET /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'HEAD /api/library/metadata/v1': '401 / 404',
  'POST /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'PUT /api/library/metadata/v1': '401 / 404 Video metadata host off',
  'GET /api/library/videos': '401 / 404 Library service off',
  'HEAD /api/library/videos': '401 / 404',
  'POST /api/library/videos': '401 / 404 Library service off',
  'PUT /api/library/videos': '401 / 404 Library service off',
  'GET /api/library/videos/v1': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1': '401 / 404',
  'POST /api/library/videos/v1': '401 / 404 Library service off',
  'PUT /api/library/videos/v1': '401 / 404 Library service off',
  'GET /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1/streamurl': '401 / 404',
  'POST /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/streamurl': '401 / 404 Library service off',
  'GET /api/library/videos/v1/stream':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/stream': '401 / 404',
  'POST /api/library/videos/v1/stream': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/stream': '401 / 404 Library service off',
  'GET /api/library/videos/v1/stream?token=bad':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/stream?token=bad': '401 / 404',
  'POST /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'PUT /api/library/videos/v1/stream?token=bad':
      '401 / 404 Library service off',
  'GET /api/library/videos/v1/hls.m3u8':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/hls.m3u8': '401 / 404',
  'POST /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/hls.m3u8': '401 / 404 Library service off',
  'GET /api/library/videos/v1/hlsseg.ts':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/hlsseg.ts': '401 / 404',
  'POST /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/hlsseg.ts': '401 / 404 Library service off',
  'GET /api/library/videos/v1/bdclip.m2ts':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/bdclip.m2ts': '401 / 404',
  'POST /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/bdclip.m2ts': '401 / 404 Library service off',
  'GET /api/library/videos/v1/sidecaraudio':
      '404 Library service off / 404 Library service off',
  'HEAD /api/library/videos/v1/sidecaraudio': '401 / 404',
  'POST /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/sidecaraudio': '401 / 404 Library service off',
  'GET /api/library/videos/v1/disc': '401 / 404 Library service off',
  'HEAD /api/library/videos/v1/disc': '401 / 404',
  'POST /api/library/videos/v1/disc': '401 / 404 Library service off',
  'PUT /api/library/videos/v1/disc': '401 / 404 Library service off',
  'GET /api/library/disc/t1/BDMV/index.bdmv':
      '404 Disc share off / 404 Disc share off',
  'HEAD /api/library/disc/t1/BDMV/index.bdmv': '401 / 404',
  'POST /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'PUT /api/library/disc/t1/BDMV/index.bdmv': '401 / 404 Disc share off',
  'GET /api/library/disc': '401 / 404 Not found',
  'HEAD /api/library/disc': '401 / 404',
  'POST /api/library/disc': '401 / 405',
  'GET /api/library/aggregate': '401 / 404 Library service off',
  'HEAD /api/library/aggregate': '401 / 404',
  'POST /api/library/aggregate': '401 / 404 Library service off',
  'PUT /api/library/aggregate': '401 / 404 Library service off',
  'GET /api/library/activity': '401 / 404 Library service off',
  'HEAD /api/library/activity': '401 / 404',
  'POST /api/library/activity': '401 / 404 Library service off',
  'PUT /api/library/activity': '401 / 404 Library service off',
  'GET /api/library/collections': '401 / 404 Library service off',
  'HEAD /api/library/collections': '401 / 404',
  'POST /api/library/collections': '401 / 404 Library service off',
  'PUT /api/library/collections': '401 / 404 Library service off',
  'GET /api/library/tags': '401 / 404 Tag sync off',
  'HEAD /api/library/tags': '401 / 404',
  'POST /api/library/tags': '401 / 404 Tag sync off',
  'PUT /api/library/tags': '401 / 404 Tag sync off',
  'GET /api/library/media-links': '401 / 404 Media link sync off',
  'HEAD /api/library/media-links': '401 / 404',
  'POST /api/library/media-links': '401 / 404 Media link sync off',
  'PUT /api/library/media-links': '401 / 404 Media link sync off',
  'GET /api/library/online-items': '401 / 404 Online library sync off',
  'HEAD /api/library/online-items': '401 / 404',
  'POST /api/library/online-items': '401 / 404 Online library sync off',
  'PUT /api/library/online-items': '401 / 404 Online library sync off',
  'GET /api/library/other': '401 / 404 Not found',
  'HEAD /api/library/other': '401 / 404',
  'POST /api/library/other': '401 / 405',
  'GET /api/interconnect/service-config':
      '401 / 403 HTTPS required for service config',
  'HEAD /api/interconnect/service-config': '401 / 405',
  'POST /api/interconnect/service-config': '401 / 405',
  'PUT /api/interconnect/service-config': '401 / 405',
  'GET /api/interconnect/source-share': '401 / 404 Source share capability off',
  'HEAD /api/interconnect/source-share': '401 / 405',
  'POST /api/interconnect/source-share': '401 / 405',
  'PUT /api/interconnect/source-share': '401 / 405',
  'GET /api/interconnect/source-share/package':
      '401 / 404 Source share capability off',
  'HEAD /api/interconnect/source-share/package': '401 / 405',
  'POST /api/interconnect/source-share/package': '401 / 405',
  'PUT /api/interconnect/source-share/package': '401 / 405',
  'GET /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay': '401 / 404',
  'POST /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay': '401 / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/invoke': '401 / 404',
  'POST /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay/invoke': '401 / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/stream/t1':
      '404 Plugin relay off / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/stream/t1': '404 / 404',
  'POST /api/interconnect/plugin-relay/stream/t1': '401 / 404 Plugin relay off',
  'PUT /api/interconnect/plugin-relay/stream/t1': '401 / 404 Plugin relay off',
  'GET /api/interconnect/plugin-relay/stream/': '401 / 404 Plugin relay off',
  'HEAD /api/interconnect/plugin-relay/stream/': '401 / 404',
  'POST /api/interconnect/plugin-relay/stream/': '401 / 404 Plugin relay off',
  'GET /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'HEAD /api/interconnect/profile': '401 / 405',
  'POST /api/interconnect/profile': '401 / 405',
  'PUT /api/interconnect/profile': '401 / 403 {"error":"https_required"}',
  'GET /api/interconnect/leaderboard-link': '401 / 405',
  'HEAD /api/interconnect/leaderboard-link': '401 / 405',
  'POST /api/interconnect/leaderboard-link':
      '401 / 403 {"error":"https_required"}',
  'PUT /api/interconnect/leaderboard-link': '401 / 405',
  'GET /api/interconnect/other': '401 / 404 Not found',
  'HEAD /api/interconnect/other': '401 / 404',
  'POST /api/interconnect/other': '401 / 405',
  'GET /api/tombstones': '401 / 404 Library service off',
  'HEAD /api/tombstones': '401 / 405',
  'POST /api/tombstones': '401 / 405',
  'PUT /api/tombstones': '401 / 405',
  'GET /api/unknown': '401 / 404 Not found',
  'HEAD /api/unknown': '401 / 404',
  'POST /api/unknown': '401 / 405',
};

/// 功能全接（明文 HTTP）的 host、不带凭据：`方法 路径` → `状态码 体`。
const Map<String, String> _kFeaturedSurface = <String, String>{
  'GET /api/pair': '401',
  'HEAD /api/pair': '401',
  'POST /api/pair': '403 {"reason":"unavailable"}',
  'PUT /api/pair': '401',
  'GET /api/pair/v2': '401',
  'HEAD /api/pair/v2': '401',
  'POST /api/pair/v2': '403 {"reason":"unavailable"}',
  'PUT /api/pair/v2': '401',
  'GET /api/pair/v2/confirm': '401',
  'HEAD /api/pair/v2/confirm': '401',
  'POST /api/pair/v2/confirm': '403 {"reason":"unavailable"}',
  'PUT /api/pair/v2/confirm': '401',
  'GET /api/pair/other': '401',
  'HEAD /api/pair/other': '401',
  'POST /api/pair/other': '401',
  'GET /api/game-stream/sessions': '401',
  'HEAD /api/game-stream/sessions': '401',
  'POST /api/game-stream/sessions': '401',
  'PUT /api/game-stream/sessions': '401',
  'GET /api/game-stream/sessions/s1': '401',
  'HEAD /api/game-stream/sessions/s1': '401',
  'POST /api/game-stream/sessions/s1': '401',
  'PUT /api/game-stream/sessions/s1': '401',
  'GET /api/game-stream/join': '401',
  'HEAD /api/game-stream/join': '401',
  'POST /api/game-stream/join': '401',
  'PUT /api/game-stream/join': '401',
  'GET /api/game-stream/signal': '401',
  'HEAD /api/game-stream/signal': '401',
  'POST /api/game-stream/signal': '401',
  'PUT /api/game-stream/signal': '401',
  'GET /api/game-stream/stop': '401',
  'HEAD /api/game-stream/stop': '401',
  'POST /api/game-stream/stop': '401',
  'PUT /api/game-stream/stop': '401',
  'GET /api/game-stream/mine': '401',
  'HEAD /api/game-stream/mine': '401',
  'POST /api/game-stream/mine': '401',
  'PUT /api/game-stream/mine': '401',
  'GET /api/game-stream/library': '401',
  'HEAD /api/game-stream/library': '401',
  'POST /api/game-stream/library': '401',
  'PUT /api/game-stream/library': '401',
  'GET /api/game-stream/library/cover': '401',
  'HEAD /api/game-stream/library/cover': '401',
  'POST /api/game-stream/library/cover': '401',
  'PUT /api/game-stream/library/cover': '401',
  'GET /api/game-stream/launch': '401',
  'HEAD /api/game-stream/launch': '401',
  'POST /api/game-stream/launch': '401',
  'PUT /api/game-stream/launch': '401',
  'GET /api/game-stream/launch/status': '401',
  'HEAD /api/game-stream/launch/status': '401',
  'POST /api/game-stream/launch/status': '401',
  'PUT /api/game-stream/launch/status': '401',
  'GET /api/game-stream/other': '401',
  'HEAD /api/game-stream/other': '401',
  'POST /api/game-stream/other': '401',
  'GET /api/video-remote/play': '401',
  'HEAD /api/video-remote/play': '401',
  'POST /api/video-remote/play': '401',
  'PUT /api/video-remote/play': '401',
  'GET /api/video-remote/nope': '401',
  'HEAD /api/video-remote/nope': '401',
  'POST /api/video-remote/nope': '401',
  'PUT /api/video-remote/nope': '401',
  'GET /api/video-remote': '401',
  'HEAD /api/video-remote': '401',
  'POST /api/video-remote': '401',
  'GET /api/lookup/word': '401',
  'HEAD /api/lookup/word': '401',
  'POST /api/lookup/word': '401',
  'PUT /api/lookup/word': '401',
  'GET /api/lookup/audio/file': '404 Not found',
  'HEAD /api/lookup/audio/file': '404',
  'POST /api/lookup/audio/file': '401',
  'PUT /api/lookup/audio/file': '401',
  'GET /api/lookup': '401',
  'HEAD /api/lookup': '401',
  'POST /api/lookup': '401',
  'GET /api/mine': '401',
  'HEAD /api/mine': '401',
  'POST /api/mine': '401',
  'PUT /api/mine': '401',
  'GET /api/mine/targets': '401',
  'HEAD /api/mine/targets': '401',
  'POST /api/mine/targets': '401',
  'PUT /api/mine/targets': '401',
  'GET /api/mine/forward': '401',
  'HEAD /api/mine/forward': '401',
  'POST /api/mine/forward': '401',
  'PUT /api/mine/forward': '401',
  'GET /api/mine/other': '401',
  'HEAD /api/mine/other': '401',
  'POST /api/mine/other': '401',
  'GET /api/anki/note-type/x': '401',
  'HEAD /api/anki/note-type/x': '401',
  'POST /api/anki/note-type/x': '401',
  'PUT /api/anki/note-type/x': '401',
  'GET /api/anki/source/x': '401',
  'HEAD /api/anki/source/x': '401',
  'POST /api/anki/source/x': '401',
  'PUT /api/anki/source/x': '401',
  'GET /api/anki/media/dedup/x': '401',
  'HEAD /api/anki/media/dedup/x': '401',
  'POST /api/anki/media/dedup/x': '401',
  'PUT /api/anki/media/dedup/x': '401',
  'GET /api/anki/other': '401',
  'HEAD /api/anki/other': '401',
  'POST /api/anki/other': '401',
  'GET /api/media/dictionary': '401',
  'HEAD /api/media/dictionary': '401',
  'POST /api/media/dictionary': '401',
  'PUT /api/media/dictionary': '401',
  'GET /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401',
  'HEAD /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401',
  'POST /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401',
  'PUT /api/media/dictionary?dictionary=d&path=a.svg&key=bad': '401',
  'GET /api/duplicate': '401',
  'HEAD /api/duplicate': '401',
  'POST /api/duplicate': '401',
  'PUT /api/duplicate': '401',
  'GET /api/extension/status': '401',
  'HEAD /api/extension/status': '401',
  'POST /api/extension/status': '401',
  'PUT /api/extension/status': '401',
  'GET /api/ping': '200',
  'HEAD /api/ping': '401',
  'POST /api/ping': '401',
  'PUT /api/ping': '401',
  'GET /api/srs/changes': '401',
  'HEAD /api/srs/changes': '401',
  'POST /api/srs/changes': '401',
  'PUT /api/srs/changes': '401',
  'GET /api/srs/sync-status': '401',
  'HEAD /api/srs/sync-status': '401',
  'POST /api/srs/sync-status': '401',
  'PUT /api/srs/sync-status': '401',
  'GET /api/srs/remote/review': '401',
  'HEAD /api/srs/remote/review': '401',
  'POST /api/srs/remote/review': '401',
  'PUT /api/srs/remote/review': '401',
  'GET /api/srs/remote2/review': '401',
  'HEAD /api/srs/remote2/review': '401',
  'POST /api/srs/remote2/review': '401',
  'PUT /api/srs/remote2/review': '401',
  'GET /api/srs/other': '401',
  'HEAD /api/srs/other': '401',
  'POST /api/srs/other': '401',
  'GET /api/ai/relay/providers': '401',
  'HEAD /api/ai/relay/providers': '401',
  'POST /api/ai/relay/providers': '401',
  'PUT /api/ai/relay/providers': '401',
  'GET /api/ai/relay': '401',
  'HEAD /api/ai/relay': '401',
  'POST /api/ai/relay': '401',
  'GET /api/capabilities': '401',
  'HEAD /api/capabilities': '401',
  'POST /api/capabilities': '401',
  'PUT /api/capabilities': '401',
  'GET /api/host/addresses': '401',
  'HEAD /api/host/addresses': '401',
  'POST /api/host/addresses': '401',
  'PUT /api/host/addresses': '401',
  'GET /api/host/update': '401',
  'HEAD /api/host/update': '401',
  'POST /api/host/update': '401',
  'PUT /api/host/update': '401',
  'GET /api/ocr/screen': '401',
  'HEAD /api/ocr/screen': '401',
  'POST /api/ocr/screen': '401',
  'PUT /api/ocr/screen': '401',
  'GET /api/ocr/job': '401',
  'HEAD /api/ocr/job': '401',
  'POST /api/ocr/job': '401',
  'PUT /api/ocr/job': '401',
  'GET /api/jobs': '401',
  'HEAD /api/jobs': '401',
  'POST /api/jobs': '401',
  'PUT /api/jobs': '401',
  'GET /api/downloads': '401',
  'HEAD /api/downloads': '401',
  'POST /api/downloads': '401',
  'PUT /api/downloads': '401',
  'GET /api/torrent-engine': '401',
  'HEAD /api/torrent-engine': '401',
  'POST /api/torrent-engine': '401',
  'PUT /api/torrent-engine': '401',
  'GET /api/subscriptions': '401',
  'HEAD /api/subscriptions': '401',
  'POST /api/subscriptions': '401',
  'PUT /api/subscriptions': '401',
  'GET /api/assistant': '401',
  'HEAD /api/assistant': '401',
  'POST /api/assistant': '401',
  'PUT /api/assistant': '401',
  'GET /api/library/manga-chapter-progress': '401',
  'HEAD /api/library/manga-chapter-progress': '401',
  'POST /api/library/manga-chapter-progress': '401',
  'PUT /api/library/manga-chapter-progress': '401',
  'GET /api/library/music': '401',
  'HEAD /api/library/music': '401',
  'POST /api/library/music': '401',
  'GET /api/library/media/streamurl': '401',
  'HEAD /api/library/media/streamurl': '401',
  'POST /api/library/media/streamurl': '401',
  'PUT /api/library/media/streamurl': '401',
  'GET /api/library/media/stream': '401 Missing token',
  'HEAD /api/library/media/stream': '401',
  'POST /api/library/media/stream': '401',
  'PUT /api/library/media/stream': '401',
  'GET /api/library/media/stream?token=bad': '403 Invalid or expired token',
  'HEAD /api/library/media/stream?token=bad': '403',
  'POST /api/library/media/stream?token=bad': '401',
  'PUT /api/library/media/stream?token=bad': '401',
  'GET /api/library/media/streamrelease': '401',
  'HEAD /api/library/media/streamrelease': '401',
  'POST /api/library/media/streamrelease': '401',
  'PUT /api/library/media/streamrelease': '401',
  'GET /api/library/dictionaries': '401',
  'HEAD /api/library/dictionaries': '401',
  'POST /api/library/dictionaries': '401',
  'PUT /api/library/dictionaries': '401',
  'GET /api/library/dictionaries/d1': '401',
  'HEAD /api/library/dictionaries/d1': '401',
  'POST /api/library/dictionaries/d1': '401',
  'PUT /api/library/dictionaries/d1': '401',
  'GET /api/library/book-progress': '401',
  'HEAD /api/library/book-progress': '401',
  'POST /api/library/book-progress': '401',
  'PUT /api/library/book-progress': '401',
  'GET /api/library/books': '401',
  'HEAD /api/library/books': '401',
  'POST /api/library/books': '401',
  'PUT /api/library/books': '401',
  'GET /api/library/books/b1': '401',
  'HEAD /api/library/books/b1': '401',
  'POST /api/library/books/b1': '401',
  'PUT /api/library/books/b1': '401',
  'GET /api/library/manga': '401',
  'HEAD /api/library/manga': '401',
  'POST /api/library/manga': '401',
  'GET /api/library/manga/m1': '401',
  'HEAD /api/library/manga/m1': '401',
  'POST /api/library/manga/m1': '401',
  'PUT /api/library/manga/m1': '401',
  'GET /api/library/localaudio': '401',
  'HEAD /api/library/localaudio': '401',
  'POST /api/library/localaudio': '401',
  'PUT /api/library/localaudio': '401',
  'GET /api/library/localaudio/a1': '401',
  'HEAD /api/library/localaudio/a1': '401',
  'POST /api/library/localaudio/a1': '401',
  'PUT /api/library/localaudio/a1': '401',
  'GET /api/library/audiobooks': '401',
  'HEAD /api/library/audiobooks': '401',
  'POST /api/library/audiobooks': '401',
  'PUT /api/library/audiobooks': '401',
  'GET /api/library/audiobooks/a1': '401',
  'HEAD /api/library/audiobooks/a1': '401',
  'POST /api/library/audiobooks/a1': '401',
  'PUT /api/library/audiobooks/a1': '401',
  'GET /api/library/metadata': '401',
  'HEAD /api/library/metadata': '401',
  'POST /api/library/metadata': '401',
  'PUT /api/library/metadata': '401',
  'GET /api/library/metadata/v1': '401',
  'HEAD /api/library/metadata/v1': '401',
  'POST /api/library/metadata/v1': '401',
  'PUT /api/library/metadata/v1': '401',
  'GET /api/library/videos': '401',
  'HEAD /api/library/videos': '401',
  'POST /api/library/videos': '401',
  'PUT /api/library/videos': '401',
  'GET /api/library/videos/v1': '401',
  'HEAD /api/library/videos/v1': '401',
  'POST /api/library/videos/v1': '401',
  'PUT /api/library/videos/v1': '401',
  'GET /api/library/videos/v1/streamurl': '401',
  'HEAD /api/library/videos/v1/streamurl': '401',
  'POST /api/library/videos/v1/streamurl': '401',
  'PUT /api/library/videos/v1/streamurl': '401',
  'GET /api/library/videos/v1/stream': '401 Missing token',
  'HEAD /api/library/videos/v1/stream': '401',
  'POST /api/library/videos/v1/stream': '401',
  'PUT /api/library/videos/v1/stream': '401',
  'GET /api/library/videos/v1/stream?token=bad': '403 Invalid or expired token',
  'HEAD /api/library/videos/v1/stream?token=bad': '401',
  'POST /api/library/videos/v1/stream?token=bad': '401',
  'PUT /api/library/videos/v1/stream?token=bad': '401',
  'GET /api/library/videos/v1/hls.m3u8': '401 Missing token',
  'HEAD /api/library/videos/v1/hls.m3u8': '401',
  'POST /api/library/videos/v1/hls.m3u8': '401',
  'PUT /api/library/videos/v1/hls.m3u8': '401',
  'GET /api/library/videos/v1/hlsseg.ts': '401 Missing token',
  'HEAD /api/library/videos/v1/hlsseg.ts': '401',
  'POST /api/library/videos/v1/hlsseg.ts': '401',
  'PUT /api/library/videos/v1/hlsseg.ts': '401',
  'GET /api/library/videos/v1/bdclip.m2ts': '401 Missing token',
  'HEAD /api/library/videos/v1/bdclip.m2ts': '401',
  'POST /api/library/videos/v1/bdclip.m2ts': '401',
  'PUT /api/library/videos/v1/bdclip.m2ts': '401',
  'GET /api/library/videos/v1/sidecaraudio': '401 Missing token',
  'HEAD /api/library/videos/v1/sidecaraudio': '401',
  'POST /api/library/videos/v1/sidecaraudio': '401',
  'PUT /api/library/videos/v1/sidecaraudio': '401',
  'GET /api/library/videos/v1/disc': '401',
  'HEAD /api/library/videos/v1/disc': '401',
  'POST /api/library/videos/v1/disc': '401',
  'PUT /api/library/videos/v1/disc': '401',
  'GET /api/library/disc/t1/BDMV/index.bdmv': '401 Disc share session expired',
  'HEAD /api/library/disc/t1/BDMV/index.bdmv': '401',
  'POST /api/library/disc/t1/BDMV/index.bdmv': '401',
  'PUT /api/library/disc/t1/BDMV/index.bdmv': '401',
  'GET /api/library/disc': '401',
  'HEAD /api/library/disc': '401',
  'POST /api/library/disc': '401',
  'GET /api/library/aggregate': '401',
  'HEAD /api/library/aggregate': '401',
  'POST /api/library/aggregate': '401',
  'PUT /api/library/aggregate': '401',
  'GET /api/library/activity': '401',
  'HEAD /api/library/activity': '401',
  'POST /api/library/activity': '401',
  'PUT /api/library/activity': '401',
  'GET /api/library/collections': '401',
  'HEAD /api/library/collections': '401',
  'POST /api/library/collections': '401',
  'PUT /api/library/collections': '401',
  'GET /api/library/tags': '401',
  'HEAD /api/library/tags': '401',
  'POST /api/library/tags': '401',
  'PUT /api/library/tags': '401',
  'GET /api/library/media-links': '401',
  'HEAD /api/library/media-links': '401',
  'POST /api/library/media-links': '401',
  'PUT /api/library/media-links': '401',
  'GET /api/library/online-items': '401',
  'HEAD /api/library/online-items': '401',
  'POST /api/library/online-items': '401',
  'PUT /api/library/online-items': '401',
  'GET /api/library/other': '401',
  'HEAD /api/library/other': '401',
  'POST /api/library/other': '401',
  'GET /api/interconnect/service-config': '401',
  'HEAD /api/interconnect/service-config': '401',
  'POST /api/interconnect/service-config': '401',
  'PUT /api/interconnect/service-config': '401',
  'GET /api/interconnect/source-share': '401',
  'HEAD /api/interconnect/source-share': '401',
  'POST /api/interconnect/source-share': '401',
  'PUT /api/interconnect/source-share': '401',
  'GET /api/interconnect/source-share/package': '401',
  'HEAD /api/interconnect/source-share/package': '401',
  'POST /api/interconnect/source-share/package': '401',
  'PUT /api/interconnect/source-share/package': '401',
  'GET /api/interconnect/plugin-relay': '401',
  'HEAD /api/interconnect/plugin-relay': '401',
  'POST /api/interconnect/plugin-relay': '401',
  'PUT /api/interconnect/plugin-relay': '401',
  'GET /api/interconnect/plugin-relay/invoke': '401',
  'HEAD /api/interconnect/plugin-relay/invoke': '401',
  'POST /api/interconnect/plugin-relay/invoke': '401',
  'PUT /api/interconnect/plugin-relay/invoke': '401',
  'GET /api/interconnect/plugin-relay/stream/t1': '404 Unknown stream ticket',
  'HEAD /api/interconnect/plugin-relay/stream/t1': '404',
  'POST /api/interconnect/plugin-relay/stream/t1': '401',
  'PUT /api/interconnect/plugin-relay/stream/t1': '401',
  'GET /api/interconnect/plugin-relay/stream/': '401',
  'HEAD /api/interconnect/plugin-relay/stream/': '401',
  'POST /api/interconnect/plugin-relay/stream/': '401',
  'GET /api/interconnect/profile': '401',
  'HEAD /api/interconnect/profile': '401',
  'POST /api/interconnect/profile': '401',
  'PUT /api/interconnect/profile': '401',
  'GET /api/interconnect/leaderboard-link': '401',
  'HEAD /api/interconnect/leaderboard-link': '401',
  'POST /api/interconnect/leaderboard-link': '401',
  'PUT /api/interconnect/leaderboard-link': '401',
  'GET /api/interconnect/other': '401',
  'HEAD /api/interconnect/other': '401',
  'POST /api/interconnect/other': '401',
  'GET /api/tombstones': '401',
  'HEAD /api/tombstones': '401',
  'POST /api/tombstones': '401',
  'PUT /api/tombstones': '401',
  'GET /api/unknown': '401',
  'HEAD /api/unknown': '401',
  'POST /api/unknown': '401',
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

/// 对照表探测的方法。PUT 只探 `/api/` 下已知路由，不往 WebDAV 树里写东西（见 [_writesIntoDav]）。
const List<String> _kProbeMethods = <String>['GET', 'HEAD', 'POST', 'PUT'];

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

/// 发一个请求，回 `状态码 体`（非 2xx 才带体；体截 60 字符，空白压成一个空格）。
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
    // 2xx 只记状态码：成功体里有端口、长轮询令牌这类每次都变的值，对照表管的是门，不是正文。
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return '${res.statusCode}';
    }
    String body = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll(RegExp(r'\s+'), ' ');
    if (body.length > 60) body = body.substring(0, 60);
    return '${res.statusCode} $body'.trimRight();
  } finally {
    client.close(force: true);
  }
}

/// PUT 到不归任何路由的路径会在 WebDAV 树里落文件；对照表不这么探。
bool _writesIntoDav(String method, String path) =>
    method == 'PUT' &&
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

  test('功能全接：免 Basic 的面不变（不带凭据）', () async {
    final FushiSyncServer server = _maximalServer(tmp.path, tls: false);
    await server.start();
    addTearDown(server.stop);
    final Map<String, String> actual = <String, String>{};
    for (final (String method, String path) in _probeKeys()) {
      actual['$method $path'] = await _probe(server, method, path);
    }
    _report('featured surface', actual);
    expect(actual, _kFeaturedSurface);
  });
}
