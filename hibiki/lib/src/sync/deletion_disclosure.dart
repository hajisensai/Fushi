import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

/// 删除目标的种类。删除确认框据此逐项披露「会删什么 / 会保留什么」，不再由各调用点
/// 手写一句笼统正文。
///
/// 加新目标时必须同时在 [buildDeletionDisclosure] 的 switch 里补分支（穷尽 switch
/// 没有 default，漏了编译期就报错），并在 `deletion_disclosure_test.dart` 里补一条
/// 「披露集合 == 真实删除集合」的行为断言。
enum DeletionDisclosureTarget {
  /// 书架里的书（EPUB / 漫画 / PDF / 字幕书）。单删与批量删走同一底层链路
  /// `ReaderHibikiSource.deleteBook`，披露内容因此完全一致。
  shelfBook,

  /// 已附加的有声书。只删有声书，书本身留在架上。
  attachedAudiobook,
}

/// 结构化删除披露：一组「会被删除」+ 一组「会被保留」的人话条目。
///
/// 这是纯数据，不含 Widget，可以在单测里与真实删除行为逐项对照——这正是本类存在的
/// 理由：确认文案与实际删除范围必须由同一份事实派生，否则又会漂开。
class DeletionDisclosure {
  const DeletionDisclosure({required this.willDelete, required this.willKeep});

  /// 确认后真的会从本机消失的东西。
  final List<String> willDelete;

  /// 确认后仍然留着的东西——尤其是用户自己导入的原始文件。
  final List<String> willKeep;
}

/// 按 [target] 构造删除披露。
///
/// 不收 Slang 翻译参数：生成出来的字符串类是私有的 `_StringsEn`，没法出现在公开签名
/// 里；全局 `t` 本来就是这些弹窗统一的取词方式，测试用 `LocaleSettings.setLocale`
/// 控制语言即可。除当前 locale 外无其它输入，仍是确定性纯函数。
DeletionDisclosure buildDeletionDisclosure({
  required DeletionDisclosureTarget target,
}) {
  switch (target) {
    case DeletionDisclosureTarget.shelfBook:
      // 真实删除集合见 ReaderHibikiSource.deleteBook：
      //   1) HibikiDatabase.deleteEpubBook 事务删阅读进度/书签/字幕 cue/有声书行/
      //      书架行/标签映射；
      //   2) AudiobookStorage.deletePersistDir(bookKey) 与 (srt.uid) 递归删
      //      `<documents>/audiobooks/<hash>`；
      //   3) EpubStorage.deleteBookDir(extractDir) 递归删 `<documents>/hoshi_books/<key>`。
      // 不删：epub_books.epubPath 只存文件名，删除路径从不据它删用户原始文件；
      //       reading_statistics / reading_hourly_logs 无人清理，确实留着。
      return DeletionDisclosure(
        willDelete: <String>[
          t.delete_disclosure_book_records,
          t.delete_disclosure_book_extracted,
          t.delete_disclosure_book_audiobook,
        ],
        willKeep: <String>[
          t.delete_disclosure_source_kept,
          t.delete_disclosure_stats_kept,
        ],
      );
    case DeletionDisclosureTarget.attachedAudiobook:
      // 真实删除集合见 AudiobookRepository.deleteAudiobook：
      //   1) deleteAudiobookByBookKey 删 audio_cues / shelf_entries / audiobooks 行；
      //   2) AudiobookStorage.deletePersistDir(bookKey) 递归删整个持久化目录。
      // 书本身、解压目录、阅读进度都不动。
      return DeletionDisclosure(
        willDelete: <String>[
          t.delete_disclosure_audiobook_files,
        ],
        willKeep: <String>[
          t.delete_disclosure_audiobook_book_kept,
          t.delete_disclosure_audiobook_source_kept,
        ],
      );
  }
}

/// 把 [DeletionDisclosure] 渲染成确认框里的「会被删除 / 会被保留」两段列表。
///
/// 书架删除确认框（`ReaderHistoryDeleteDialog`）与通用删除确认框
/// （`showDeleteScopeConfirm`）共用本视图，保证两处披露长得一样、也不会各自漂移。
class DeletionDisclosureView extends StatelessWidget {
  const DeletionDisclosureView({required this.disclosure, super.key});

  final DeletionDisclosure disclosure;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    Widget section({
      required String label,
      required IconData icon,
      required Color color,
      required List<String> items,
    }) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: color),
              SizedBox(width: tokens.spacing.gap / 2),
              Flexible(
                child: Text(
                  label,
                  style: tokens.type.listSubtitle.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          for (final String item in items)
            Padding(
              padding: EdgeInsets.only(
                left: tokens.spacing.gap + tokens.spacing.gap / 2,
                top: tokens.spacing.gap / 4,
              ),
              child: Text(
                '• $item',
                style: tokens.type.listSubtitle.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        section(
          label: t.delete_disclosure_will_delete_label,
          icon: Icons.delete_outline,
          color: colors.error,
          items: disclosure.willDelete,
        ),
        SizedBox(height: tokens.spacing.gap),
        section(
          label: t.delete_disclosure_will_keep_label,
          icon: Icons.shield_outlined,
          color: colors.primary,
          items: disclosure.willKeep,
        ),
      ],
    );
  }
}
