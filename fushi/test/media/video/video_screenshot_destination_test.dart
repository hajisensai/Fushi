import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_screenshot_destination.dart';
import 'package:fushi/src/profile/profile_keys.dart';

void main() {
  group('VideoScreenshotDestination', () {
    test('storageValue 往返稳定（落盘值是冻结契约）', () {
      for (final VideoScreenshotDestination destination
          in VideoScreenshotDestination.values) {
        expect(
          VideoScreenshotDestination.fromStorage(destination.storageValue),
          destination,
        );
      }
    });

    test('落盘值逐字冻结', () {
      expect(VideoScreenshotDestination.ask.storageValue, 'ask');
      expect(VideoScreenshotDestination.clipboard.storageValue, 'clipboard');
      expect(VideoScreenshotDestination.directory.storageValue, 'directory');
    });

    test('未知值 / 空库回落到 ask，即这个偏好出现之前的行为', () {
      expect(
        VideoScreenshotDestination.fromStorage(null),
        VideoScreenshotDestination.ask,
      );
      expect(
        VideoScreenshotDestination.fromStorage(''),
        VideoScreenshotDestination.ask,
      );
      expect(
        VideoScreenshotDestination.fromStorage('gallery'),
        VideoScreenshotDestination.ask,
      );
    });
  });

  group('Profile 归属', () {
    test('截图目录不随 Profile 走（描述的是这台设备的磁盘）', () {
      // 与 download_save_root 同族：切 Profile 不该把截图重定向到本机不存在的路径。
      expect(ProfileKeys.isExcludedPref(kVideoScreenshotDirectoryPref), isTrue);
    });

    test('去向枚举是真偏好，照常随 Profile 走', () {
      expect(
          ProfileKeys.isExcludedPref(kVideoScreenshotDestinationPref), isFalse);
    });
  });
}
