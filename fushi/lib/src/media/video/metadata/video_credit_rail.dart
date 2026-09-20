/// 作品详情页的人物关系轨道（配音 / 演职人员）：一人一张竖卡，照片 + 姓名 +
/// 角色或职位。合集详情页与单文件作品页共用同一份，两页的照片来源与回退规则
/// 不会再各自漂移（BUG-2612：单文件作品页此前只画文字 Chip，结构上没有照片）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(height: tokens.spacing.card),
        SizedBox(
          height: 224,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              scrollDirection: Axis.horizontal,
              itemCount: credits.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.card),
              itemBuilder: (BuildContext context, int index) {
                final VideoMetadataCreditSummary credit = credits[index];
                final VideoCreditCardImage? image =
                    videoCreditCardImage(credit);
                return SizedBox(
                  key: ValueKey<String>(
                      '$keyPrefix-${credit.person.personKey}-$index'),
                  width: 132,
                  child: FushiCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: image == null
                              ? const _CreditPlaceholder()
                              : Image(
                                  image: image.image,
                                  fit: BoxFit.cover,
                                  // BUG-2496：坏头像文件解码失败退回占位，不当致命错误。
                                  errorBuilder: (_, Object error, __) {
                                    ErrorLogService.instance.logDiagnostic(
                                      'VideoCreditRail.coverDecode',
                                      '${image.source}: $error',
                                    );
                                    return const _CreditPlaceholder();
                                  },
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 8, 9, 2),
                          child: Text(
                            credit.person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
                          child: Text(
                            credit.character?.name ??
                                (credit.roleName.isEmpty
                                    ? credit.creditKind
                                    : credit.roleName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _CreditPlaceholder extends StatelessWidget {
  const _CreditPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0x1FFFFFFF),
        child: Icon(Icons.person_outline, size: 42),
      );
}
