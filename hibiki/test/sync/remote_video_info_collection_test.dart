import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

/// 守卫：`RemoteVideoInfo.fromJson` 必须解析 `collection` 归属字段。此前 toJson 写了
/// `collection` 但 fromJson 从不读 → LAN 远端视频 `video.collection` 恒 null → 首页收不到
/// 合集分组（全成散卡），播放器也无从重建合集连播（互联视频「缺合集列表/无连播」根因之一）。
void main() {
  test('fromJson 解析 collection 归属（合集分组根因）', () {
    final RemoteVideoInfo info = RemoteVideoInfo.fromJson(<String, Object?>{
      'id': 'video/series/ep1',
      'title': 'Episode 1',
      'collection': <String, Object?>{
        'name': 'My Series',
        'collectionType': 'playlist',
        'sortIndex': 3,
      },
    });
    expect(info.collection, isNotNull);
    expect(info.collection!.collectionName, 'My Series');
    expect(info.collection!.collectionType, 'playlist');
    expect(info.collection!.sortIndex, 3);
  });

  test('fromJson 无 collection → null（旧 host 向后兼容，降级散卡）', () {
    final RemoteVideoInfo info = RemoteVideoInfo.fromJson(<String, Object?>{
      'id': 'v',
      'title': 't',
    });
    expect(info.collection, isNull);
  });

  test('toJson→fromJson 往返保留 collection（协议闭环）', () {
    final RemoteVideoInfo original = RemoteVideoInfo.fromJson(<String, Object?>{
      'id': 'v',
      'title': 't',
      'collection': <String, Object?>{
        'name': 'C',
        'collectionType': 'collection',
        'sortIndex': 2,
      },
    });
    final RemoteVideoInfo restored =
        RemoteVideoInfo.fromJson(original.toJson());
    expect(restored.collection?.collectionName, 'C');
    expect(restored.collection?.collectionType, 'collection');
    expect(restored.collection?.sortIndex, 2);
  });
}
