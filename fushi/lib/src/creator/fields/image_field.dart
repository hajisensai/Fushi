import 'package:carousel_slider/carousel_slider.dart' hide CarouselController;
import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:progress_indicators/progress_indicators.dart';
import 'package:gap/gap.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';

/// Returns audio information from context.
class ImageField extends ImageExportField {
  /// Initialise this field with the predetermined and hardset values.
  ImageField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Image',
          description: 'Visual supplement. Text field can be used to enter'
              ' search terms for image sources.',
          icon: Icons.image_outlined,
        );

  /// Get the singleton instance of this field.
  static ImageField get instance => _instance;

  static final ImageField _instance = ImageField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'image';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_image;

  @override
  Widget buildTopWidget({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Orientation orientation,
  }) {
    if (isSearching) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (orientation == Orientation.landscape)
            Flexible(
              child: Container(
                color: Colors.transparent,
                height: double.infinity,
                width: double.infinity,
              ),
            )
          else
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.transparent,
                height: double.infinity,
                width: double.infinity,
              ),
            ),
          const Gap(10),
          buildFooterLoading(
            appModel: appModel,
            context: context,
          ),
        ],
      );
    }

    if (!showWidget) {
      return const SizedBox.shrink();
    }

    int itemCount = currentImageSuggestions!.length;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (orientation == Orientation.landscape)
          Flexible(
            child: buildCarousel(
              itemCount: itemCount,
              ref: ref,
              appModel: appModel,
              creatorModel: creatorModel,
            ),
          )
        else
          buildCarousel(
            itemCount: itemCount,
            ref: ref,
            appModel: appModel,
            creatorModel: creatorModel,
          ),
        const Gap(10),
        ValueListenableBuilder<int?>(
          valueListenable: indexNotifier,
          builder: (context, index, _) => buildFooterTextSpans(
            context: context,
            appModel: appModel,
            itemCount: itemCount,
          ),
        ),
      ],
    );
  }

  /// 长按预览的全屏遮罩层。**必须是字段而不是 `buildCarousel` 里的局部变量**：
  /// 局部变量随每一轮 build 重新创建，按住期间 carousel 只要重建一次（页码
  /// notifier 变化、建卡器 setState），`onLongPressEnd` 拿到的就是新一轮那个
  /// 恒为 null 的变量，旧遮罩永远留在 overlay 最上层。它不是路由，iOS 既没有
  /// 系统返回键、侧滑返回也只作用于路由，用户唯一的出路是杀进程重启。
  OverlayEntry? _longPressPreview;

  void _dismissLongPressPreview() {
    final OverlayEntry? entry = _longPressPreview;
    if (entry == null) {
      return;
    }
    _longPressPreview = null;
    removeAndDisposeOwnedOverlayEntry(entry);
  }

  /// Build the image carousel.
  Widget buildCarousel({
    required int itemCount,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
  }) {
    return ChangeNotifierBuilder(
      notifier: carouselNotifier,
      builder: (_, __, ___) {
        return CarouselSlider.builder(
          key: carouselKey,
          itemCount: itemCount + 1,
          options: CarouselOptions(
            enlargeStrategy: CenterPageEnlargeStrategy.zoom,
            enlargeCenterPage: true,
            viewportFraction: 0.75,
            initialPage: indexNotifier.value,
            onPageChanged: (index, reason) {
              if (index == itemCount) {
                indexNotifier.value = -1;
                setSelectedSearchSuggestion(index: -1);
              } else {
                indexNotifier.value = index;
                setSelectedSearchSuggestion(index: index);
              }
            },
          ),
          itemBuilder: (context, index, realIndex) {
            if (index == itemCount) {
              return Container(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.12),
              );
            }

            ImageProvider<Object> image = currentImageSuggestions![index];

            return GestureDetector(
              onTap: () {
                if (index != indexNotifier.value) {
                  return;
                }
                final cropEnhancement = appModel.enhancements[
                    ImageField.instance]![CropImageEnhancement.key]!;

                cropEnhancement.enhanceCreatorParams(
                  context: context,
                  ref: ref,
                  appModel: appModel,
                  creatorModel: creatorModel,
                  cause: EnhancementTriggerCause.manual,
                );
              },
              onLongPress: () {
                if (index != indexNotifier.value) {
                  return;
                }
                _dismissLongPressPreview();
                final OverlayEntry preview = OverlayEntry(
                  builder: (context) => GestureDetector(
                    // 遮罩自己也要能点掉：手势状态机漏掉 end/cancel（按住期间
                    // carousel 重建、指针被系统手势抢走）时，这是仅剩的出口。
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismissLongPressPreview,
                    child: ColoredBox(
                      color: Theme.of(context)
                          .colorScheme
                          .scrim
                          .withValues(alpha: 0.5),
                      child: buildImage(image: image, fit: BoxFit.contain),
                    ),
                  ),
                );
                _longPressPreview = preview;
                Overlay.of(context).insert(preview);
              },
              onLongPressEnd: (details) => _dismissLongPressPreview(),
              onLongPressCancel: _dismissLongPressPreview,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: buildImage(
                  image: currentImageSuggestions![index],
                  fit: BoxFit.fitHeight,
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Build the given image and fade in to load if network.
  Widget buildImage({
    required ImageProvider<Object> image,
    required BoxFit fit,
  }) {
    return FadeInImage(
      fadeInDuration: const Duration(milliseconds: 200),
      key: ValueKey(image),
      image: image,
      placeholder: MemoryImage(kTransparentImage),
      fit: fit,
    );
  }

  /// Get the footer under the carousel that returns the current image index.
  Widget buildFooterTextSpans({
    required BuildContext context,
    required AppModel appModel,
    required int itemCount,
  }) {
    double fontSize =
        (Theme.of(context).textTheme.labelMedium?.fontSize)! * 0.9;

    return Text.rich(
      TextSpan(
        text: '',
        children: <InlineSpan>[
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(
                top: 1.25,
                right: 4,
              ),
              child: Icon(
                icon,
                size: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (selectedIndex == -1)
            TextSpan(
              text: t.image_search_label_none_before,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (selectedIndex == -1)
            TextSpan(
              text: t.image_search_label_none_middle,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            ),
          if (selectedIndex != -1)
            TextSpan(
              text: t.image_search_label_before,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (selectedIndex != -1)
            TextSpan(
              text: '${selectedIndex! + 1} ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            ),
          TextSpan(
            text: t.image_search_label_middle,
            style: TextStyle(
              fontSize: fontSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: '$itemCount ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
          if (currentSearchTerm != null && currentSearchTerm!.trim().isNotEmpty)
            TextSpan(
              text: t.image_search_label_after,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (currentSearchTerm != null && currentSearchTerm!.trim().isNotEmpty)
            TextSpan(
              text: ' ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (currentSearchTerm != null && currentSearchTerm!.trim().isNotEmpty)
            TextSpan(
              text: currentSearchTerm,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Get the footer under the carousel that returns the current image index.
  Widget buildFooterLoading({
    required BuildContext context,
    required AppModel appModel,
  }) {
    double fontSize =
        (Theme.of(context).textTheme.labelMedium?.fontSize)! * 0.9;

    return Text.rich(
      TextSpan(
        text: '',
        children: <InlineSpan>[
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(
                top: 1.25,
                right: 4,
              ),
              child: Icon(
                icon,
                size: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (currentSearchTerm != null && currentSearchTerm!.trim().isNotEmpty)
            TextSpan(
              text: t.searching_in_progress,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (currentSearchTerm != null && currentSearchTerm!.trim().isNotEmpty)
            TextSpan(
              text: currentSearchTerm,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            )
          else
            TextSpan(
              text: t.processing_in_progress,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          WidgetSpan(
            child: SizedBox(
              width: 10,
              child: JumpingDotsProgressIndicator(
                color: Theme.of(context).appBarTheme.foregroundColor!,
              ),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
