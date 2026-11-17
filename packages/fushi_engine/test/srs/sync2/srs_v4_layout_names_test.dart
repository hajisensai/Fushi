// 协议 4 的位置布局（G8-1，native/fushi_fsrs/src/gen4/location.rs）对互联 host 的约束：host 只把
// `devices/<设备>/seg-….bin` 当成那台设备自己写的段（据此认定写段的对端就是这台设备，设计 §4.1）。新根里别的设备
// 代写或附带的文件——承袭段 `hrt-`、中继件 `rly-`、被转发的 head `rhd-`、媒体清单 `mf-`、profile 说明文件——一个都不能命中它。
// 文件名取自 location_tests.rs 的冻结值。
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:test/test.dart';

const String _dir = '0193a1b2-0000-7000-8000-00000000beef';
const String _uploader = '0194b0c1-3333-7444-8555-666677778888';
const String _oldDevice = '0193a1b2-9999-7aaa-8bbb-cccccccccccc';

String _v4(String rest) =>
    '$kSyncRootFolderName/$kSrsSync2Namespace/$_dir/v4/devices/$_uploader/$rest';

void main() {
  test('only the author-written seg- file names the uploading device', () {
    expect(
      srsHostUploadedSegmentDevice(
        _v4('seg-000000000013-000000000040-c3c3c3c3.bin'),
      ),
      _uploader,
    );
    for (final String name in <String>[
      'hrt-ebc943af-$_oldDevice-000000000001-000000004321-5a5a5a5a.bin',
      'rly-000000000013-000000000040-c3c3c3c3.bin',
      'rhd-000000000007-7e7e7e7e.json',
      'mf-000000000003-0a1b2c3d.bin',
      'head-000000000007-7e7e7e7e.json',
      'profile.json',
    ]) {
      expect(srsHostUploadedSegmentDevice(_v4(name)), isNull, reason: name);
    }
  });

  test('top-level v4 files and loc markers are not device segments', () {
    for (final String rest in <String>[
      'v4/meta.json',
      'v4/joined.json',
      'v4/loc/0194b0c1-2222-7abc-9def-0123456789ab',
      'v3/meta.json',
    ]) {
      final String path =
          '$kSyncRootFolderName/$kSrsSync2Namespace/$_dir/$rest';
      expect(srsHostUploadedSegmentDevice(path), isNull, reason: rest);
      expect(srsHostPathDir(path), _dir, reason: rest);
    }
  });

  test('the host path names a directory, never a bogus one', () {
    const String ns = '$kSyncRootFolderName/$kSrsSync2Namespace';
    // 对端写的路径不可信：空目录段、`.` / `..`、不在复习命名空间里一律不是任何目录。
    for (final String path in <String>[
      '$ns/',
      '$ns//v4/meta.json',
      '$ns/./v4/meta.json',
      '$ns/../v4/meta.json',
      '$kSyncRootFolderName/books/$_dir/v4/meta.json',
      'other/$kSrsSync2Namespace/$_dir/v4/meta.json',
    ]) {
      expect(srsHostPathDir(path), isNull, reason: path);
    }
    // 目录段就是目录名，不论长什么样（新代全新集合的目录名 = 建它的 uid，但不一定是本机 uid，设计 §5.1）。
    expect(srsHostPathDir('$ns/zz-remote/v4/meta.json'), 'zz-remote');
    expect(srsHostPathDir('$ns/$_dir'), _dir);
  });
}
