/// 作品详情页的人物关系轨道（配音 / 演职人员）：一人一枚圆形头像卡，照片 +
/// 姓名 + 角色或职位。合集详情页与单文件作品页共用同一份，两页的照片来源与回退规则
/// 不会再各自漂移（BUG-2612：单文件作品页此前只画文字 Chip，结构上没有照片）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一条人物关系在卡片上该显示的图：先人物照（本地落地 > 远端 URL），声优没有
/// 人物照时退到角色图——AniDB / MAL 对角色图的覆盖率远高于声优照，卡片上本来
/// 就同时印着声优名与角色名，退到角色图不会认错人。Shoko 的 Role 模型也是
/// 角色图与人物图并列两张，只是这里卡位只够一张。
VideoCreditCardImage? videoCreditCardImage(
  VideoMetadataCreditSummary credit,
) {
  final VideoCreditCardImage? person = _imageFor(
    credit.person.profilePath,
    credit.person.profileUrl,
  );
  if (person != null || credit.creditKind != 'voice_actor') return person;
  final VideoMetadataCharacterSummary? character = credit.character;
  return character == null
      ? null
      : _imageFor(character.imagePath, character.imageUrl);
}

/// 卡片图与它的来源（本地路径或 URL，只用于诊断日志）。
typedef VideoCreditCardImage = ({ImageProvider image, String source});

VideoCreditCardImage? _imageFor(String? path, String? url) {
  if (path != null && File(path).existsSync()) {
    return (image: FileImage(File(path)), source: path);
  }
  return url == null ? null : (image: AppCachedHttpImage(url), source: url);
}

/// 人物横滑轨道（M3E）：区块标题 + 计数胶囊，一人一枚圆形头像卡（照片 + 姓名 +
/// 角色或职位），错峰进场。视觉是作品详情共享骨架的 [MediaDetailCastStrip]；这里
/// 只负责把规范人物行换成纯值——照片来源与回退规则（[videoCreditCardImage]）、
/// 坏图诊断日志（BUG-2496）与测试 key 前缀都留在本文件。
class VideoCreditRail extends StatelessWidget {
  const VideoCreditRail({
    required this.title,
    required this.credits,
    required this.tokens,
    this.keyPrefix = 'video-work-credit',
    super.key,
  });

  final String title;
  final List<VideoMetadataCreditSummary> credits;
  final FushiDesignTokens tokens;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return MediaDetailCastStrip(
      title: title,
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      people: <MediaDetailPerson>[
        for (int index = 0; index < credits.length; index++)
          _personOf(credits[index], index),
      ],
    );
  }

  MediaDetailPerson _personOf(VideoMetadataCreditSummary credit, int index) {
    final VideoCreditCardImage? image = videoCreditCardImage(credit);
    return MediaDetailPerson(
      key: ValueKey<String>('$keyPrefix-${credit.person.personKey}-$index'),
      name: credit.person.name,
      role: credit.character?.name ??
          (credit.roleName.isEmpty ? credit.creditKind : credit.roleName),
      image: image?.image,
      // BUG-2496：坏头像文件解码失败退回占位（骨架里画），不当致命错误。
      onImageError: image == null
          ? null
          : (Object error) => ErrorLogService.instance.logDiagnostic(
                'VideoCreditRail.coverDecode',
                '${image.source}: $error',
              ),
    );
  }
}
