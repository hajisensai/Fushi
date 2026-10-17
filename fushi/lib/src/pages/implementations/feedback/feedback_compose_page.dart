// 提交反馈：分类 / 标题 / 描述 / 联系方式 + 截图（默认带上打开反馈前的画面；可从
// 相册选、也可直接粘贴剪贴板里的截图——桌面 Ctrl/Cmd+V、描述框长按菜单「粘贴图片」、
// 显式「粘贴图片」按钮、Android 输入法插入的图片）+
// 附带日志与设备信息开关 + 已登录排行榜账户时「以 xx 身份提交」+ 可选 1 个视频（上传前
// 本机转码成 720p（默认）/ 1080p，≤ 50 MB，见 feedback_video.dart；显示压缩 / 上传进度）。
// 成功后 `pop(FeedbackSubmitResult)`，失败就地显示原因（不靠 toast，用户要一直看得到）。
//
// 视频选完就在后台压缩（用户边写边压），换档位即取消在途压缩按新档位重压；表单在压缩期间
// 不锁（BUG-3489），× 随时取消压缩并移除视频。点提交时还没压完：提交按钮显示压缩进度，
// 压完按表单此刻的内容自动发出；压缩失败则撤销这次提交，附件行给出原因与「重新压缩」。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_draft_store.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/utils/misc/clipboard_image.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

/// 「问题没解决，重新提交」的原反馈：用来预填提交页（分类 / 标题 / 正文），截图可选带上。
class FeedbackReopenSeed {
  const FeedbackReopenSeed({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    this.screenshotSlots = const <String>[],
  });

  /// 从原反馈详情构造（截图槽位按服务端返回的附件清单）。
  factory FeedbackReopenSeed.fromDetail(FeedbackDetail d) => FeedbackReopenSeed(
    id: d.id,
    category: d.summary.category,
    title: d.summary.title,
    body: d.body,
    screenshotSlots: <String>[
      for (final FeedbackAttachmentInfo a in d.attachments)
        if (a.isScreenshot) a.slot,
    ],
  );

  final String id;
  final FeedbackCategory category;
  final String title;
  final String body;
  final List<String> screenshotSlots;
}

/// [_FeedbackComposePageState._onDisk]：磁盘上没有草稿。
const Object _kNoDraftOnDisk = Object();

class FeedbackComposePage extends ConsumerStatefulWidget {
  const FeedbackComposePage({this.initialScreenshot, this.reopenOf, super.key});

  final Uint8List? initialScreenshot;

  /// 非空 = 基于这条已结案的反馈重新提交（不读写草稿：草稿属于普通的新反馈）。
  final FeedbackReopenSeed? reopenOf;

  @override
  ConsumerState<FeedbackComposePage> createState() =>
      _FeedbackComposePageState();
}

class _FeedbackComposePageState extends ConsumerState<FeedbackComposePage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.bug;
  late final List<Uint8List> _shots = <Uint8List>[?widget.initialScreenshot];
  bool _includeLogs = true;
  bool _includeDevice = true;
  bool _linkAccount = true;
  FeedbackSubmitStage? _stage;
  String? _error;

  /// 选的视频（原件路径）与它的大小。不进草稿：草稿只存表单文字与截图。
  File? _video;
  int _videoBytes = 0;

  /// 视频压缩 / 上传进度（0..1；拿不到时长时为 null）。
  double? _videoFraction;
  bool _pickingVideo = false;

  /// 压缩档位（默认 720p，只在本页有效，不进草稿）。
  FeedbackVideoQuality _videoQuality = FeedbackVideoQuality.p720;

  /// 进行中的压缩的取消开关（× / 换档 / 离开页面时完成它）；没在压缩时为 null。
  Completer<void>? _videoCancel;

  /// 压缩任务代号：每开一次新压缩 / 取消就 +1，旧任务的回调与结果按它丢弃。
  int _videoJob = 0;

  /// 选完视频就在后台压（用户边写边压）：正在压、压好的产物、压缩失败的原因。
  bool _compressing = false;
  FeedbackStagedVideo? _staged;
  Object? _videoError;

  /// 点了提交、视频还没压完：压完自动发出（提交按钮显示压缩进度）；压缩失败或点 × 撤销。
  bool _submitWaiting = false;

  /// 提交幂等键与它对应的表单内容（BUG-3489 审查）：同样的内容再点一次提交 = 重试同一次
  /// 提交，带同一个键——正文其实已经到了服务端（回执没收到 / 本机落盘失败）时拿回的是
  /// 同一条反馈，不会多出一条重复反馈。内容改过就是一次新提交，换新键。
  String? _submissionKey;
  String? _submissionSignature;

  /// 本次提交要带的幂等键：内容与上一次提交相同就沿用，否则换新。
  String _submissionKeyFor(String title, String body, String contact) {
    final String signature = jsonEncode(<Object?>[
      _category.wire,
      title,
      body,
      contact,
      widget.reopenOf?.id,
    ]);
    final String? key = _submissionKey;
    if (key != null && signature == _submissionSignature) return key;
    _submissionSignature = signature;
    return _submissionKey = newFeedbackSubmissionKey();
  }

  /// 选了 1080p，但这段视频 1080p 装不进上限，本次改按 720p 压。
  bool _videoDowngraded = false;

  /// 正在读剪贴板：Ctrl+V 与菜单 / 按钮同时触发时只读一次，避免同一张图加两遍。
  bool _pasting = false;

  bool get _busy => _stage != null;

  /// 表单是否锁住：只有正文发出之后（发送 / 传附件）才锁。等视频压完期间不锁——压缩可能
  /// 要好几分钟，期间文字、截图、开关、档位都还能改，视频的 × 可取消（BUG-3489）。
  bool get _locked => _busy && _stage != FeedbackSubmitStage.videoPrepare;

  /// 联系方式框里是「上次用过的联系方式」预填的值（不算用户新写的草稿内容）。
  String _prefilledContact = '';

  int get _room => FeedbackLimits.screenshots - _shots.length;

  // ---- 草稿（FeedbackDraftStore，本机一份）----

  /// 草稿读完之前不写：否则「还是空表单」会把磁盘上的草稿清掉。
  bool _draftLoaded = false;

  /// 提交成功后不再存（草稿已清）。
  bool _submitted = false;

  /// 本次打开恢复了草稿：显示「已恢复 · 丢弃草稿」。
  int? _restoredAt;
  Timer? _draftTimer;
  late final AppLifecycleListener _lifecycle;

  /// 磁盘上草稿此刻的内容：[_kNoDraftOnDisk] = 没有草稿，[FeedbackComposeDraft] = 上次
  /// 写下去的那份，null = 不知道（下一次落盘照写）。落盘前与它比，没变就不写——桌面
  /// 主窗每次失焦都会触发落盘，每次都整份重写（连同最多 3 张截图）是纯写放大（BUG-3241）。
  Object? _onDisk;

  /// initState 里取一次：dispose 时还要用它落盘，那时已不能再碰 ref。
  late final FeedbackService _service;

  static const Duration _kDraftDebounce = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    _service = ref.read(feedbackServiceProvider);
    HardwareKeyboard.instance.addHandler(_onKey);
    for (final TextEditingController c in <TextEditingController>[
      _title,
      _body,
      _contact,
    ]) {
      c.addListener(_scheduleDraftSave);
    }
    // 进后台（切走 / 锁屏 / 可能随后被杀）时立刻落盘，不等防抖。
    _lifecycle = AppLifecycleListener(
      onStateChange: (AppLifecycleState state) {
        if (state != AppLifecycleState.resumed) _flushDraft();
      },
    );
    final FeedbackReopenSeed? seed = widget.reopenOf;
    if (seed == null) {
      unawaited(_loadDraft());
    } else {
      _category = seed.category;
      _title.text = seed.title;
      _body.text = seed.body;
      unawaited(_prefillContact());
    }
  }

  /// 联系方式默认带上次提交用的那个。必须在草稿读完之后做：草稿里的联系方式（哪怕
  /// 是空）以草稿为准；用户已经开始填了也不覆盖。
  Future<void> _prefillContact() async {
    final String last = await _service.lastContact();
    if (!mounted ||
        last.isEmpty ||
        _contact.text.isNotEmpty ||
        _restoredAt != null) {
      return;
    }
    _prefilledContact = last;
    _contact.text = last;
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleDraftSave();
  }

  /// 用户写过东西没有（与刚打开时的空表单 + 自动截图比）。
  bool get _hasDraftContent =>
      _title.text.trim().isNotEmpty ||
      _body.text.trim().isNotEmpty ||
      _contact.text.trim() != _prefilledContact ||
      _category != FeedbackCategory.bug ||
      !_includeLogs ||
      !_includeDevice ||
      !_linkAccount ||
      _shots.length != (widget.initialScreenshot == null ? 0 : 1) ||
      (_shots.isNotEmpty && !identical(_shots.first, widget.initialScreenshot));

  Future<void> _loadDraft() async {
    try {
      final FeedbackComposeDraft? draft = await (await _service.draftStore())
          .read();
      if (!mounted) return;
      _onDisk = draft ?? _kNoDraftOnDisk;
      // 草稿读回来之前用户已经动手写了：以眼前的为准，下一次保存覆盖旧草稿。
      if (draft != null && !_hasDraftContent) {
        super.setState(() {
          _category = draft.category;
          _includeLogs = draft.includeLogs;
          _includeDevice = draft.includeDevice;
          _linkAccount = draft.linkAccount;
          _shots
            ..clear()
            ..addAll(draft.screenshots);
          // 本次打开前自动截的画面接在草稿截图后面（还有空位、且不是草稿里已有的同一张）：
          // 它是打开反馈那一刻的现场，关掉提交页就再也截不回来（BUG-3240）。
          final Uint8List? autoShot = widget.initialScreenshot;
          if (autoShot != null &&
              _room > 0 &&
              !draft.screenshots.any(
                (Uint8List s) => listEquals(s, autoShot),
              )) {
            _shots.add(autoShot);
          }
          _restoredAt = draft.savedAt;
        });
        _title.text = draft.title;
        _body.text = draft.body;
        _contact.text = draft.contact;
      }
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.draft_load', e, st);
    } finally {
      _draftLoaded = true;
      _draftTimer?.cancel();
    }
    await _prefillContact();
  }

  void _scheduleDraftSave() {
    if (!_draftLoaded || _submitted) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(_kDraftDebounce, _flushDraft);
  }

  /// 立刻按当前表单写草稿（表单空了就删掉草稿）。不等结果：离开页面时也要能调。
  void _flushDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (!_draftLoaded || _submitted) return;
    final bool keep = _hasDraftContent;
    final FeedbackComposeDraft draft = FeedbackComposeDraft(
      category: _category,
      title: _title.text,
      body: _body.text,
      contact: _contact.text,
      includeLogs: _includeLogs,
      includeDevice: _includeDevice,
      linkAccount: _linkAccount,
      screenshots: List<Uint8List>.of(_shots),
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final Object target = keep ? draft : _kNoDraftOnDisk;
    if (_sameOnDisk(_onDisk, target)) return;
    _onDisk = target;
    unawaited(
      _service
          .draftStore()
          .then(
            (FeedbackDraftStore store) =>
                keep ? store.write(draft) : store.clear(),
          )
          .catchError((Object e, StackTrace st) {
            ErrorLogService.instance.log('feedback.draft_save', e, st);
            // 没写成：磁盘上是什么不知道了，下一次照写。
            if (identical(_onDisk, target)) _onDisk = null;
          }),
    );
  }

  /// 两份草稿状态是否一样（不比保存时刻；截图按引用比——表单里的截图对象只在增删时换）。
  static bool _sameOnDisk(Object? a, Object b) {
    if (identical(a, b)) return true;
    if (a is! FeedbackComposeDraft || b is! FeedbackComposeDraft) return false;
    if (a.category != b.category ||
        a.title != b.title ||
        a.body != b.body ||
        a.contact != b.contact ||
        a.includeLogs != b.includeLogs ||
        a.includeDevice != b.includeDevice ||
        a.linkAccount != b.linkAccount ||
        a.screenshots.length != b.screenshots.length) {
      return false;
    }
    for (int i = 0; i < a.screenshots.length; i++) {
      if (!identical(a.screenshots[i], b.screenshots[i])) return false;
    }
    return true;
  }

  /// 「丢弃草稿」：删掉磁盘上的草稿，表单回到刚打开时的样子（带本次的自动截图、
  /// 上次提交用的联系方式）。
  void _discardDraft() {
    _draftTimer?.cancel();
    _title.text = '';
    _body.text = '';
    _contact.text = _prefilledContact;
    super.setState(() {
      _category = FeedbackCategory.bug;
      _includeLogs = true;
      _includeDevice = true;
      _linkAccount = true;
      _shots
        ..clear()
        ..addAll(<Uint8List>[?widget.initialScreenshot]);
      _restoredAt = null;
      _error = null;
    });
    _draftTimer?.cancel();
    _onDisk = _kNoDraftOnDisk;
    unawaited(
      _service
          .draftStore()
          .then((FeedbackDraftStore store) => store.clear())
          .catchError((Object e, StackTrace st) {
            ErrorLogService.instance.log('feedback.draft_clear', e, st);
          }),
    );
    // 恢复了草稿时打开页面那次预填被草稿让掉了（[_prefilledContact] 还是空的）：草稿
    // 没了，联系方式回到「上次提交用的那个」，与没有草稿时打开一样。
    unawaited(_prefillContact());
  }

  @override
  void dispose() {
    // 离开页面：进行中的压缩一并中止（强杀 ffmpeg、清掉半成品），压好没发的产物也删掉。
    _cancelVideoCompression();
    unawaited(_staged?.discard());
    _staged = null;
    // 返回 / 切走页面：把还在防抖里的改动落盘。
    _flushDraft();
    _lifecycle.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _title.dispose();
    _body.dispose();
    _contact.dispose();
    super.dispose();
  }

  // ---- 重新提交 ----

  /// 「带上原截图」开着时加进来的那几张（关掉时按引用移除）。
  final List<Uint8List> _parentShots = <Uint8List>[];
  bool _includeParentShots = false;
  bool _loadingParentShots = false;

  Future<void> _toggleParentShots(bool on) async {
    final FeedbackReopenSeed seed = widget.reopenOf!;
    if (!on) {
      setState(() {
        _includeParentShots = false;
        _shots.removeWhere(
          (Uint8List s) => _parentShots.any((Uint8List p) => identical(p, s)),
        );
        _parentShots.clear();
      });
      return;
    }
    setState(() {
      _includeParentShots = true;
      _loadingParentShots = true;
    });
    int failed = 0;
    for (final String slot in seed.screenshotSlots) {
      if (_room <= 0 || !_includeParentShots) break;
      try {
        final Uint8List bytes = await _service.screenshot(seed.id, slot);
        if (!mounted || !_includeParentShots || _room <= 0) break;
        setState(() {
          _parentShots.add(bytes);
          _shots.add(bytes);
        });
      } on Object catch (e, st) {
        ErrorLogService.instance.log('feedback.reopen_screenshot', e, st);
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _loadingParentShots = false;
      // 一张都没取回：开关不能停在「已带上」。
      if (_parentShots.isEmpty) _includeParentShots = false;
    });
    // 少带了几张要让用户知道（开关看着是开的，附件里却缺图，BUG-3242）。
    if (failed > 0) _notice(t.feedback_reopen_shots_failed(n: failed));
  }

  List<Widget> _reopenSection(FushiDesignTokens tokens) {
    final FeedbackReopenSeed seed = widget.reopenOf!;
    return <Widget>[
      FushiInlineNotice(
        key: const ValueKey<String>('feedback-reopen-notice'),
        title: t.feedback_reopen_of(id: seed.id),
        message: t.feedback_reopen_notice(id: seed.id),
      ),
      if (seed.screenshotSlots.isNotEmpty)
        FushiSwitchListTile(
          key: const ValueKey<String>('feedback-reopen-include-shots'),
          value: _includeParentShots,
          onChanged: _locked || _loadingParentShots
              ? null
              : (bool v) => unawaited(_toggleParentShots(v)),
          title: Text(
            t.feedback_reopen_include_shots(n: seed.screenshotSlots.length),
          ),
        ),
      SizedBox(height: tokens.spacing.card),
    ];
  }

  Future<void> _addImage() async {
    final File? file;
    try {
      file = await pickGalleryImageFile();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.pick_image', e, st);
      return;
    }
    if (file == null) return;
    await _addRawImage(await file.readAsBytes());
  }

  /// 原始图片字节 → 按反馈上限处理 → 加进附件（满了就不加）。
  Future<void> _addRawImage(Uint8List raw) async {
    try {
      final Uint8List bytes = await prepareFeedbackImage(raw);
      if (!mounted || _room <= 0) return;
      setState(() => _shots.add(bytes));
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.prepare_image', e, st);
    }
  }

  Future<void> _pickVideo() async {
    if (_pickingVideo) return;
    _pickingVideo = true;
    try {
      final File? file = await pickFeedbackVideoFile();
      if (file == null || !mounted) return;
      final int bytes = await file.length();
      if (!mounted) return;
      setState(() {
        _video = file;
        _videoBytes = bytes;
        _error = null;
      });
      // 选完就在后台压：用户写反馈的同时压缩，点提交时多半已经压好。
      _startVideoCompression();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.pick_video', e, st);
    } finally {
      _pickingVideo = false;
    }
  }

  /// 桌面 Ctrl+V（macOS Cmd+V）：不论焦点在不在输入框都看一眼剪贴板，有图就收。
  /// 不吃掉按键——输入框里照常粘贴文字（剪贴板里只有图时那一步什么也不贴）。
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool primary = Platform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!primary || keyboard.isAltPressed || keyboard.isShiftPressed) {
      return false;
    }
    // 只认最上层：提交页上面又压了别的页面 / 弹窗时不抢。
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    unawaited(_pasteFromClipboard(explicit: false));
    return false;
  }

  /// 把剪贴板里的图片加进附件。[explicit]（按钮 / 菜单）时没图、满了、读失败都给
  /// 一句提示；Ctrl+V 粘的多半是文字，没图时不打扰。
  Future<void> _pasteFromClipboard({required bool explicit}) async {
    if (_locked || _pasting) return;
    _pasting = true;
    try {
      if (_room <= 0) {
        // 满了：剪贴板里确实有图才提示（Ctrl+V 粘文字不该冒出「图片满了」）。
        if (explicit || await readClipboardImage() != null) {
          _notice(
            t.feedback_compose_paste_full(max: FeedbackLimits.screenshots),
          );
        }
        return;
      }
      final List<Uint8List> images = await readFeedbackImagesFromClipboard(
        limit: _room,
      );
      if (!mounted) return;
      if (images.isEmpty) {
        if (explicit) _notice(t.feedback_compose_paste_none);
        return;
      }
      setState(() {
        for (final Uint8List image in images) {
          if (_room <= 0) break;
          _shots.add(image);
        }
      });
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image', e, st);
      if (explicit) _notice(t.feedback_compose_paste_failed);
    } finally {
      _pasting = false;
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 描述框的长按 / 右键菜单：系统默认项 + 「粘贴图片」（剪贴板里只有图时系统的
  /// 「粘贴」不出现，这一项总在，没图就提示）。
  Widget _bodyContextMenu(BuildContext context, EditableTextState state) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      ...state.contextMenuButtonItems,
      if (_room > 0 && !_locked)
        ContextMenuButtonItem(
          label: t.feedback_compose_paste_image,
          onPressed: () {
            state.hideToolbar();
            unawaited(_pasteFromClipboard(explicit: true));
          },
        ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// Android 输入法（如 Gboard 的剪贴板 / 贴图）直接插入的图片。
  static const List<String> _kInsertMimeTypes = <String>[
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  ];

  void _onContentInserted(KeyboardInsertedContent content) {
    final Uint8List? data = content.data;
    if (data == null || data.isEmpty || _locked || _room <= 0) return;
    unawaited(_addRawImage(data));
  }

  /// 桌面提示 Ctrl+V / ⌘V 粘贴截图；手机 / 平板提示长按正文框的菜单（那里没有
  /// 实体键盘快捷键，提 Ctrl+V 没有意义）。按目标平台判，测试里可覆盖。
  String get _pasteHint => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => t.feedback_compose_paste_hint_desktop(key: '⌘V'),
    TargetPlatform.windows || TargetPlatform.linux =>
      t.feedback_compose_paste_hint_desktop(key: 'Ctrl+V'),
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => t.feedback_compose_paste_hint_mobile,
  };

  Future<void> _submit() async {
    // 只有标题是必填：一句话说得清的反馈不必再逼人写详情（反馈 JHR0a8mT5M）。
    if (_title.text.trim().isEmpty) {
      setState(() {
        _error = t.feedback_compose_title_missing;
        if (_submitWaiting) {
          _submitWaiting = false;
          _stage = null;
        }
      });
      return;
    }
    final File? video = _video;
    if (video != null && _staged == null) {
      // 视频还没压好：压缩失败就把原因亮出来（附件行有「重新压缩」）；还在压就排队，
      // 压完由 [_runVideoCompression] 再调一次本函数自动发出。表单在此期间不锁。
      final Object? failure = _videoError;
      if (failure != null) {
        setState(() => _error = _videoErrorText(failure));
        return;
      }
      if (!_compressing) _startVideoCompression();
      setState(() {
        _error = null;
        _submitWaiting = true;
        _stage = FeedbackSubmitStage.videoPrepare;
      });
      return;
    }
    final FeedbackStagedVideo? staged = video == null ? null : _staged;
    setState(() {
      _error = null;
      _submitWaiting = false;
      _stage = FeedbackSubmitStage.sending;
    });
    final String title = _title.text.trim();
    final String body = _body.text.trim();
    final String contact = _contact.text.trim();
    final String submissionKey = _submissionKeyFor(title, body, contact);
    try {
      final FeedbackSubmitResult result = await _service.submit(
        FeedbackDraft(
          category: _category,
          title: title,
          body: body,
          contact: contact,
          includeLogs: _includeLogs,
          includeDeviceInfo: _includeDevice,
          linkAccount: _linkAccount,
          screenshots: List<Uint8List>.of(_shots),
          video: video,
          reopenOf: widget.reopenOf?.id,
          submissionKey: submissionKey,
        ),
        stagedVideo: staged,
        onStage: (FeedbackSubmitStage s) {
          if (mounted) setState(() => _stage = s);
        },
        onVideoProgress: _onVideoProgress,
      );
      _submitted = true;
      _draftTimer?.cancel();
      // 视频已挪进待传区（或已传完）：压缩产物的工作目录可以删了。
      if (identical(_staged, staged)) _staged = null;
      unawaited(staged?.discard());
      // 重新提交不读写草稿：磁盘上的草稿属于另一条还没写完的新反馈，不能被这次提交顺手删掉。
      if (widget.reopenOf == null) {
        try {
          await (await _service.draftStore()).clear();
        } on Object catch (e, st) {
          ErrorLogService.instance.log('feedback.draft_clear', e, st);
        }
      }
      if (mounted) Navigator.of(context).pop(result);
    } on Object catch (e, st) {
      // 正文没发出去：压好的视频留着，再点提交不用重压。
      ErrorLogService.instance.log('feedback.submit', e, st);
      if (!mounted) return;
      setState(() {
        _stage = null;
        _videoFraction = null;
        _error =
            feedbackVideoErrorText(e) ??
            t.feedback_submit_failed(reason: feedbackErrorReason(e));
      });
    }
  }

  /// 后台压缩失败的原因（太大 / 不是视频有专门文案，别的是通用的「压缩失败」）。
  static String _videoErrorText(Object error) =>
      feedbackVideoErrorText(error) ?? t.feedback_compose_video_failed;

  /// 按当前档位（重新）开始压缩所选视频：先取消在途的压缩、丢掉旧产物。
  void _startVideoCompression() {
    final File? video = _video;
    if (video == null) return;
    _cancelVideoCompression();
    unawaited(_staged?.discard());
    final int job = _videoJob;
    final Completer<void> cancel = Completer<void>();
    _videoCancel = cancel;
    setState(() {
      _staged = null;
      _compressing = true;
      _videoError = null;
      _videoFraction = null;
      _videoDowngraded = false;
    });
    unawaited(_runVideoCompression(job, video, cancel));
  }

  Future<void> _runVideoCompression(
    int job,
    File video,
    Completer<void> cancel,
  ) async {
    bool current() => mounted && job == _videoJob && !cancel.isCompleted;
    try {
      final FeedbackStagedVideo staged = await _service.stageVideo(
        video,
        options: FeedbackVideoPrepareOptions(
          quality: _videoQuality,
          cancel: cancel.future,
          onDowngraded: () {
            if (current()) setState(() => _videoDowngraded = true);
          },
        ),
        onProgress: (double f) {
          if (current()) _onVideoProgress(f);
        },
      );
      if (!current()) {
        await staged.discard();
        return;
      }
      setState(() {
        _staged = staged;
        _compressing = false;
        _videoFraction = null;
      });
      if (_submitWaiting) unawaited(_submit());
    } on FeedbackVideoCancelledException {
      // 被 × / 换档 / 离开页面取代：状态由取代的一方负责。
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.video_prepare', e, st);
      if (!current()) return;
      setState(() {
        _compressing = false;
        _videoFraction = null;
        _videoError = e;
        // 在等它的那次提交撤销（不悄悄发出没有视频的反馈），原因就地显示。
        if (_submitWaiting) {
          _submitWaiting = false;
          _stage = null;
          _error = _videoErrorText(e);
        }
      });
    } finally {
      if (identical(_videoCancel, cancel)) _videoCancel = null;
    }
  }

  /// 视频附件的 ×：取消压缩、移除视频，留在页面；在等压缩的那次提交一并撤销。
  void _removeVideo() {
    _cancelVideoCompression();
    unawaited(_staged?.discard());
    setState(() {
      _video = null;
      _videoBytes = 0;
      _staged = null;
      _compressing = false;
      _videoError = null;
      _videoFraction = null;
      _videoDowngraded = false;
      if (_submitWaiting) {
        _submitWaiting = false;
        _stage = null;
      }
    });
  }

  void _onVideoProgress(double? f) {
    if (!mounted) return;
    // 按整百分比刷新：上传回调按块来，几十 MB 是上千次。
    final int? before = _percentOf(_videoFraction);
    _videoFraction = f;
    if (_percentOf(f) != before || f == null) setState(() {});
  }

  /// 中止进行中的视频压缩并作废它的回调（没在压缩时只作废）。
  void _cancelVideoCompression() {
    _videoJob++;
    final Completer<void>? cancel = _videoCancel;
    _videoCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  static int? _percentOf(double? f) => f == null ? null : (f * 100).floor();

  String get _percentText {
    final int? pct = _percentOf(_videoFraction);
    return pct == null ? '' : '$pct%';
  }

  String _stageLabel(FeedbackSubmitStage stage) => switch (stage) {
    FeedbackSubmitStage.videoPrepare => t.feedback_stage_video_prepare(
      percent: _percentText,
    ),
    FeedbackSubmitStage.sending => t.feedback_stage_sending,
    FeedbackSubmitStage.screenshots => t.feedback_stage_screenshots,
    FeedbackSubmitStage.logs => t.feedback_stage_logs,
    FeedbackSubmitStage.video => t.feedback_stage_video(percent: _percentText),
  };

  /// 视频附件区：说明 + 「添加视频」或已选视频（文件名 · 状态 · ×）+ 压缩档位。选完就在
  /// 后台压：附件行显示压缩进度 / 压好的大小 / 失败原因与「重新压缩」；× 随时可点（取消
  /// 压缩并移除视频，BUG-3489），正文发出之后（上传视频时）才禁用。
  List<Widget> _videoSection(FushiDesignTokens tokens) {
    final File? video = _video;
    final FeedbackStagedVideo? staged = _staged;
    final Object? failure = _videoError;
    final bool uploading = video != null && _stage == FeedbackSubmitStage.video;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget? status = video == null
        ? null
        : _compressing || uploading
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiLinearProgressIndicator(value: _videoFraction),
                if (_compressing) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    t.feedback_stage_video_prepare(percent: _percentText),
                    key: const ValueKey<String>('feedback-video-compressing'),
                    style: tokens.type.metadata,
                  ),
                ],
              ],
            ),
          )
        : failure != null
        ? Text(
            _videoErrorText(failure),
            key: const ValueKey<String>('feedback-video-error'),
            style: tokens.type.metadata.copyWith(color: colors.error),
          )
        : staged != null
        ? Text(
            t.feedback_compose_video_compressed(
              size: FushiByteFormat.bytes(staged.video.bytes),
            ),
            key: const ValueKey<String>('feedback-video-ready'),
          )
        : Text(FushiByteFormat.bytes(_videoBytes));
    return <Widget>[
      SizedBox(height: tokens.spacing.card),
      Text(
        t.feedback_compose_video_hint(
          max: FushiByteFormat.bytes(FeedbackLimits.videoMaxBytes),
          resolution: _videoQuality.label,
        ),
        key: const ValueKey<String>('feedback-video-hint'),
        style: tokens.type.metadata,
      ),
      SizedBox(height: tokens.spacing.gap),
      if (video == null)
        Align(
          alignment: Alignment.centerLeft,
          child: _AddTile(
            key: const ValueKey<String>('feedback-add-video'),
            icon: FushiIcons.video,
            label: t.feedback_compose_add_video,
            onTap: _busy ? null : () => unawaited(_pickVideo()),
          ),
        )
      else
        FushiCard(
          key: const ValueKey<String>('feedback-video'),
          margin: EdgeInsets.zero,
          child: FushiListItem(
            leading: const FushiIcon(FushiIcons.video),
            title: Text(
              p.basename(video.path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: status,
            trailing: FushiIconButton(
              key: const ValueKey<String>('feedback-remove-video'),
              icon: FushiIcons.close,
              tooltip: _compressing
                  ? t.feedback_compose_video_cancel_remove
                  : t.feedback_compose_remove_video,
              enabled: !_locked,
              onTap: _removeVideo,
            ),
          ),
        ),
      if (video != null && failure != null && !_locked) ...<Widget>[
        SizedBox(height: tokens.spacing.gap),
        Align(
          alignment: Alignment.centerLeft,
          child: FushiTextButton(
            key: const ValueKey<String>('feedback-video-retry'),
            onPressed: _startVideoCompression,
            child: Text(t.feedback_compose_video_retry),
          ),
        ),
      ],
      if (video != null && !_locked) ...<Widget>[
        SizedBox(height: tokens.spacing.gap),
        Align(
          alignment: Alignment.centerLeft,
          child: adaptiveSegmentedButton<FeedbackVideoQuality>(
            context: context,
            segments: <ButtonSegment<FeedbackVideoQuality>>[
              for (final FeedbackVideoQuality q in FeedbackVideoQuality.values)
                ButtonSegment<FeedbackVideoQuality>(
                  value: q,
                  label: Text(
                    q.label,
                    key: ValueKey<String>('feedback-video-quality-${q.label}'),
                  ),
                ),
            ],
            selected: <FeedbackVideoQuality>{_videoQuality},
            onSelectionChanged: (Set<FeedbackVideoQuality> v) {
              if (v.first == _videoQuality) return;
              setState(() => _videoQuality = v.first);
              // 换档：取消在途压缩、丢掉旧档位的产物，按新档位重压。
              _startVideoCompression();
            },
          ),
        ),
        if (_videoQuality == FeedbackVideoQuality.p1080) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            t.feedback_compose_video_1080_hint(
              max: FushiByteFormat.bytes(FeedbackLimits.videoMaxBytes),
            ),
            key: const ValueKey<String>('feedback-video-1080-hint'),
            style: tokens.type.metadata,
          ),
        ],
      ],
      if (video != null && _videoDowngraded) ...<Widget>[
        SizedBox(height: tokens.spacing.gap),
        Text(
          t.feedback_compose_video_downgraded(
            max: FushiByteFormat.bytes(FeedbackLimits.videoMaxBytes),
          ),
          key: const ValueKey<String>('feedback-video-downgraded'),
          style: tokens.type.metadata,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardSelf? self = ref.watch(
      leaderboardServiceProvider.select((LeaderboardService s) => s.self),
    );
    final FeedbackSubmitStage? stage = _stage;
    return FushiPageScaffold(
      title: widget.reopenOf == null ? t.feedback_new : t.feedback_reopen_title,
      body: Builder(
        builder: (BuildContext context) => ListView(
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
          ),
          children: <Widget>[
            if (widget.reopenOf != null) ..._reopenSection(tokens),
            if (_restoredAt != null) ...<Widget>[
              FushiInlineNotice(
                key: const ValueKey<String>('feedback-draft-restored'),
                message: t.feedback_draft_restored(
                  time: feedbackTime(_restoredAt!),
                ),
                actions: <Widget>[
                  FushiTextButton(
                    key: const ValueKey<String>('feedback-draft-discard'),
                    onPressed: _busy ? null : _discardDraft,
                    child: Text(t.feedback_draft_discard),
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.card),
            ],
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (final FeedbackCategory c in FeedbackCategory.values)
                  FushiChoiceChip(
                    key: ValueKey<String>('feedback-category-${c.wire}'),
                    avatar: FushiIcon(feedbackCategoryIcon(c)),
                    label: Text(feedbackCategoryLabel(c)),
                    selected: _category == c,
                    onSelected: _locked
                        ? null
                        : (bool _) => setState(() => _category = c),
                  ),
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            FushiTextField(
              key: const ValueKey<String>('feedback-title'),
              controller: _title,
              enabled: !_locked,
              labelText: t.feedback_compose_title_field,
              hintText: t.feedback_compose_title_hint,
              maxLength: FeedbackLimits.titleMax,
              textInputAction: TextInputAction.next,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('feedback-body'),
              controller: _body,
              enabled: !_locked,
              labelText: t.feedback_compose_body_field,
              hintText: t.feedback_compose_body_hint,
              keyboardType: TextInputType.multiline,
              minLines: 5,
              maxLines: 12,
              maxLength: FeedbackLimits.bodyMax,
              contextMenuBuilder: _bodyContextMenu,
              contentInsertionConfiguration: ContentInsertionConfiguration(
                allowedMimeTypes: _kInsertMimeTypes,
                onContentInserted: _onContentInserted,
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('feedback-contact'),
              controller: _contact,
              enabled: !_locked,
              labelText: t.feedback_compose_contact_field,
              hintText: t.feedback_compose_contact_hint,
              maxLength: FeedbackLimits.contactMax,
            ),
            SizedBox(height: tokens.spacing.card),
            Text(
              t.feedback_compose_screenshots(
                n: _shots.length,
                max: FeedbackLimits.screenshots,
              ),
              style: tokens.type.listSubtitle,
            ),
            if (_room > 0) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                _pasteHint,
                key: const ValueKey<String>('feedback-paste-hint'),
                style: tokens.type.metadata,
              ),
            ],
            if (widget.initialScreenshot != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                t.feedback_compose_auto_shot_hint,
                key: const ValueKey<String>('feedback-auto-shot-hint'),
                style: tokens.type.metadata,
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (int i = 0; i < _shots.length; i++)
                  _Thumb(
                    key: ValueKey<String>('feedback-shot-$i'),
                    bytes: _shots[i],
                    onRemove: _locked
                        ? null
                        : () => setState(() => _shots.removeAt(i)),
                  ),
                if (_room > 0) ...<Widget>[
                  _AddTile(
                    key: const ValueKey<String>('feedback-add-image'),
                    icon: FushiIcons.addCircle,
                    label: t.feedback_compose_add_image,
                    onTap: _locked ? null : () => unawaited(_addImage()),
                  ),
                  _AddTile(
                    key: const ValueKey<String>('feedback-paste-image'),
                    icon: FushiIcons.paste,
                    label: t.feedback_compose_paste_image,
                    onTap: _locked
                        ? null
                        : () => unawaited(_pasteFromClipboard(explicit: true)),
                  ),
                ],
              ],
            ),
            ..._videoSection(tokens),
            SizedBox(height: tokens.spacing.card),
            FushiSwitchListTile(
              key: const ValueKey<String>('feedback-include-logs'),
              value: _includeLogs,
              onChanged: _locked
                  ? null
                  : (bool v) => setState(() => _includeLogs = v),
              title: Text(t.feedback_compose_attach_logs),
              subtitle: Text(t.feedback_compose_attach_logs_hint),
            ),
            FushiSwitchListTile(
              key: const ValueKey<String>('feedback-include-device'),
              value: _includeDevice,
              onChanged: _locked
                  ? null
                  : (bool v) => setState(() => _includeDevice = v),
              title: Text(t.feedback_compose_attach_device),
              subtitle: Text(t.feedback_compose_attach_device_hint),
            ),
            if (self != null)
              FushiSwitchListTile(
                key: const ValueKey<String>('feedback-link-account'),
                value: _linkAccount,
                onChanged: _locked
                    ? null
                    : (bool v) => setState(() => _linkAccount = v),
                title: Text(
                  t.feedback_compose_link_account(name: self.account.nickname),
                ),
                subtitle: Text(t.feedback_compose_link_account_hint),
              ),
            SizedBox(height: tokens.spacing.gap),
            Text(t.feedback_compose_privacy, style: tokens.type.metadata),
            if (_error != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _error!,
                key: const ValueKey<String>('feedback-compose-error'),
                style: tokens.type.listSubtitle.copyWith(color: colors.error),
              ),
            ],
            SizedBox(height: tokens.spacing.card),
            FushiPressScale(
              enabled: !_busy,
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('feedback-submit'),
                onPressed: _busy ? null : () => unawaited(_submit()),
                icon: stage == null
                    ? const FushiIcon(FushiIcons.upload)
                    : const SizedBox.square(
                        dimension: 18,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      ),
                label: Text(
                  stage == null
                      ? t.feedback_compose_submit
                      : _stageLabel(stage),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件区方块的统一尺寸：缩略图与「添加图片」/「粘贴图片」同宽同高同圆角，`Wrap`
/// 放不下就换行（窄屏 360dp 下一行两三个）。
const double _kTileWidth = 96;
const double _kTileHeight = 128;

/// 附件区的「添加图片」/「粘贴图片」方块：图标 + 一行小字。
class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      width: _kTileWidth,
      height: _kTileHeight,
      child: FushiCard(
        onTap: onTap,
        padding: EdgeInsets.zero,
        margin: EdgeInsets.zero,
        borderRadius: FushiM3eShape.smallRadius,
        child: FushiTooltip(
          message: label,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                FushiIcon(icon),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 已添加的截图：cover 填满方块，删除钮在右上角。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.onRemove, super.key});

  final Uint8List bytes;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _kTileWidth,
      height: _kTileHeight,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
            borderRadius: FushiM3eShape.smallRadius,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.containerOf(FushiTone.neutral),
              ),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    const Center(child: FushiIcon(FushiIcons.brokenImage)),
              ),
            ),
          ),
          // 浅色截图上也看得清边界。
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: FushiM3eShape.smallRadius,
              border: Border.all(color: colors.outlineVariant),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: FushiIconButton(
              icon: FushiIcons.close,
              tooltip: t.feedback_compose_remove_image,
              enabled: onRemove != null,
              onTap: onRemove ?? () {},
              size: 16,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
              backgroundColor: colors.surface.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
