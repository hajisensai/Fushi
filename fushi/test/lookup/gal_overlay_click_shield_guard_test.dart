// BUG-2613 — galgame 覆盖窗口（桌面字典卡 / hook 台词浮窗 / 穿透工具条）上的物理
// 左键被**采样型**引擎看见而推进台词。
//
// 这些窗口都是 WS_EX_NOACTIVATE 置顶窗，点它们时游戏仍是前台：Win32 消息型引擎
// （KiriKiri 等）本来就看不到落在别的窗口上的点击，但 HUNEX / Leaf 每帧
// GetAsyncKeyState、SGRE 读 DirectInput 状态、其它引擎走 RawInput——它们不看消息，
// 物理键一按就动。注入侧的 v19 输入盾（generic_input_shield.inc + exact adapter）
// 能对游戏隐藏这类采样，但它只认共享内存里的 LookupShieldRequest，而这三种窗口从不
// 发布请求。修法：窗口把自己登记到 low_level_mouse_hook 的覆盖窗口表，WH_MOUSE_LL
// 回调对落在登记窗口上的左键 down 同步发布 owner=Popup 的请求、up 发布 release，
// 事件本身不吞。
//
// 系统级 WH_MOUSE_LL、共享内存与注入进程在 Dart 测试里伪造不了；这里锁住可自动
// 证明的最强结构：回调路径的形状（不吞、回调安全发布、在 g_target 闸门之前）、
// 钩子生命周期把登记算进「要装着」、四类窗口的登记/撤销点、以及注入侧对 Popup
// owner 的接受面（generic / HUNEX / smash 不按 owner_kind 区分）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final String hookHeader = read('windows/runner/low_level_mouse_hook.h');
  final String hookSource = read('windows/runner/low_level_mouse_hook.cpp');
  final String readerHeader = read('windows/runner/voice_hook_reader.h');
  final String readerSource = read('windows/runner/voice_hook_reader.cpp');
  final String cardSource = read('windows/runner/global_lookup_window.cpp');
  final String lyricSource = read('windows/runner/floating_lyric_window.cpp');
  final String toolbarSource = read('windows/runner/hook_toolbar_window.cpp');
  final String flutterWindowSource = read('windows/runner/flutter_window.cpp');
  final String genericShield = read(
    '../native/galgame_hook/hook/generic_input_shield.inc',
  );
  final String hunexRuntime = read(
    '../native/galgame_hook/hook/adapters/hunex_gge_lookup_runtime.inc',
  );
  final String smashLookup = read(
    '../native/galgame_hook/hook/adapters/smash_fzmedia_lookup.inc',
  );
  final String ipcHeader = read(
    '../native/galgame_hook/include/voice_hook_ipc.h',
  );

  group('runner: 覆盖窗口登记表', () {
    test('头文件暴露登记 / 撤销 / 解析器三件套', () {
      final String header = compactCode(hookHeader);
      expect(
        header.contains(
          'voidSetOverlayClickShieldGameResolver(HWND(*resolver)());',
        ),
        isTrue,
      );
      expect(
        header.contains('voidRegisterOverlayClickShield(HWNDoverlay);'),
        isTrue,
      );
      expect(
        header.contains('voidUnregisterOverlayClickShield(HWNDoverlay);'),
        isTrue,
      );
    });

    test('登记表是不可变快照，登记只在有游戏时装钩子，撤空后走宽限期卸载', () {
      final String register = compactCode(
        methodBody(hookSource, 'void RegisterOverlayClickShield(HWND overlay)'),
      );
      // 解析器在锁外跑（它 EnumWindows），表在 g_binding_mutex 下整表替换。
      final int resolve = register.indexOf('resolver()');
      final int lock = register.indexOf(
        'std::lock_guard<std::mutex>guard(g_binding_mutex);',
      );
      expect(resolve, greaterThanOrEqualTo(0));
      expect(lock, greaterThan(resolve), reason: '解析器必须在锁外');
      expect(
        register.contains('if(count==0){'),
        isTrue,
        reason: '没有可保护的游戏不为它装钩子',
      );
      expect(
        register.contains('PostThreadMessage(thread_id,kThreadArm,0,0);'),
        isTrue,
      );

      final String unregister = compactCode(
        methodBody(
          hookSource,
          'void UnregisterOverlayClickShield(HWND overlay)',
        ),
      );
      expect(
        unregister.contains(
          'if(count!=0||g_target.load(std::memory_order_acquire)!=nullptr){return;}',
        ),
        isTrue,
        reason: '还有别的登记或查词卡目标时不能触发卸载',
      );
      expect(
        unregister.contains('PostThreadMessage(thread_id,kThreadDisarm,0,0);'),
        isTrue,
      );
    });

    test('钩子生命周期以 HookWanted 为准（登记表算「要装着」）', () {
      final String thread = compactCode(
        hookSource.substring(
          hookSource.indexOf('void HookThreadMain()'),
          hookSource.indexOf('DWORD EnsureHookThread()'),
        ),
      );
      final String hookWanted = compactCode(
        methodBody(hookSource, 'bool HookWanted()'),
      );
      expect(hookWanted.contains('g_target.load'), isTrue);
      expect(hookWanted.contains('g_overlay_shield_count.load'), isTrue);
      // 存活性补装与宽限期卸载两处都问 HookWanted，而不是裸看 g_target。
      expect(
        thread.contains('if(HookWanted()){if(hook==nullptr){'),
        isTrue,
        reason: '存活性补装必须把登记表算进去',
      );
      expect(
        thread.contains(
          'if(hook!=nullptr&&!HookWanted()){UnhookWindowsHookEx(hook);',
        ),
        isTrue,
        reason: '登记着覆盖窗口时不许卸钩',
      );
      expect(
        thread.contains(
          'g_overlay_transaction_id.load(std::memory_order_relaxed)!=0;',
        ),
        isTrue,
        reason: '在飞的覆盖窗口事务要算进 has_pending_button',
      );
      expect(
        thread.contains(
          'ReconcileOverlayClickShieldTransactionWithPhysicalState()',
        ),
        isTrue,
        reason: '宽限期定时器要对账覆盖窗口事务（丢 up 时补发 release）',
      );
    });
  });

  group('runner: WH_MOUSE_LL 回调', () {
    final String hookProc = compactCode(
      hookSource.substring(
        hookSource.indexOf('LRESULT CALLBACK HookProc('),
        hookSource.indexOf('void HookThreadMain()'),
      ),
    );

    test('左键 down 在 g_target 闸门之前发布护盾请求；up 在闸门之前发布 release', () {
      final int begin = hookProc.indexOf(
        'BeginOverlayClickShieldTransaction(info->pt);',
      );
      final int targetGate = hookProc.indexOf(
        'constHWNDtarget=g_target.load(std::memory_order_acquire);',
      );
      expect(begin, greaterThanOrEqualTo(0));
      expect(
        begin,
        lessThan(targetGate),
        reason: '台词浮窗 / 工具条上的点击没有查词卡目标，必须在闸门之前处理',
      );
      expect(
        hookProc.contains(
          'if(wparam==WM_LBUTTONDOWN){BeginOverlayClickShieldTransaction(info->pt);}',
        ),
        isTrue,
        reason: '只有左键（首期只拥有裸左击，与 v19 一致）',
      );
      final int end = hookProc.indexOf('EndOverlayClickShieldTransaction();');
      expect(end, greaterThanOrEqualTo(0));
      expect(end, lessThan(targetGate));
      expect(
        hookProc.contains(
          'if(wparam==WM_LBUTTONUP){EndAttachedGlyphTransaction(info->pt);EndOverlayClickShieldTransaction();}',
        ),
        isTrue,
      );
    });

    test('Begin 不吞事件、只做回调安全发布', () {
      final String begin = compactCode(
        methodBody(
          hookSource,
          'void BeginOverlayClickShieldTransaction(POINT pt)',
        ),
      );
      expect(
        begin.contains('return1;'),
        isFalse,
        reason: '事件必须照常投给我方窗口，护盾只对游戏的采样面生效',
      );
      expect(
        begin.contains('TryPublishOverlayClickShieldTransaction('),
        isTrue,
      );
      expect(
        begin.contains('PublishLookupShieldTransaction('),
        isFalse,
        reason: '回调里不许走会重试一秒的常规发布',
      );
      expect(begin.contains('lock_guard'), isFalse);
      // 快门先于任何系统调用：没有登记也没有在飞事务时纯比较早退。
      final int gate = begin.indexOf('g_overlay_shield_count.load');
      final int windowFromPoint = begin.indexOf('OverlayClickShieldGameAt(pt)');
      expect(gate, greaterThanOrEqualTo(0));
      expect(windowFromPoint, greaterThan(gate));
      // 新 down 先结束旧事务（丢 up / release 发布失败的兜底）。
      expect(
        begin.indexOf('EndOverlayClickShieldTransaction()'),
        lessThan(windowFromPoint),
      );
      // release 补不上时旧事务必须保留：Begin 里只有「新 down 发布成功」这一条
      // 路能覆盖 id，绝不能先清零——新 down 不落在覆盖窗口上时旧请求就永远停在
      // down，游戏里之后的每一次左键都会被藏掉。
      expect(
        begin.contains('g_overlay_transaction_id.store(0'),
        isFalse,
        reason: 'Begin 不许无条件清空旧事务',
      );
    });

    test('命中判定认窗口本身与其顶层祖先，跳过没有游戏的条目', () {
      final String at = compactCode(
        methodBody(hookSource, 'HWND OverlayClickShieldGameAt(POINT pt)'),
      );
      expect(at.contains('WindowFromPoint(pt)'), isTrue);
      expect(
        at.contains('GetAncestor(hit,GA_ROOT)'),
        isTrue,
        reason: 'WebView2 的宿主子 HWND 要归到卡片顶层窗',
      );
      expect(at.contains('if(entry.game==nullptr)continue;'), isTrue);
      expect(
        at.contains('GetWindowRect'),
        isFalse,
        reason: '包围矩形会把级联卡之间的透明缝隙也算成命中',
      );
    });

    test('release 发布失败时事务保留，三条重试路都在；孤儿事务才放弃', () {
      final String end = compactCode(
        methodBody(hookSource, 'bool EndOverlayClickShieldTransaction()'),
      );
      expect(
        end.contains(
          'TryPublishOverlayClickShieldTransaction(game,id,false)==0){',
        ),
        isTrue,
      );
      // 写者忙 → 事务保留（否则请求槽永远停在 down）；gate 已关 / 槽位已被别的
      // owner 或事务接管 → release 永远发不出去或只会盖掉别人的 down，按 attached
      // 的 fail-open 退役口径放弃，钩子线程才不会每 3s 为死事务续命。
      expect(
        end.contains(
          'if(!VoiceHookReader::Instance().OverlayClickShieldTransactionOrphaned(game,id)){returnfalse;}',
        ),
        isTrue,
        reason: '只有「忙」才保留；孤儿事务必须放弃',
      );
      expect(
        end.indexOf('OverlayClickShieldTransactionOrphaned'),
        lessThan(end.indexOf('g_overlay_transaction_id.store(0')),
      );
      // 第三条路的前半：down 发布成功后必须安排宽限期定时器，否则常见配置下
      // 定时器根本不存在（Arm 处理器没有挂起按键就把它杀了），对账永远不跑。
      final String begin = compactCode(
        methodBody(
          hookSource,
          'void BeginOverlayClickShieldTransaction(POINT pt)',
        ),
      );
      final int stored = begin.indexOf('g_overlay_transaction_id.store(id');
      expect(stored, greaterThanOrEqualTo(0));
      expect(
        begin.indexOf('RequestAttachedGlyphPhysicalReconciliation();'),
        greaterThan(stored),
        reason: 'down 发布成功后安排 3s 物理键态对账',
      );
      final String reconcile = compactCode(
        methodBody(
          hookSource,
          'bool ReconcileOverlayClickShieldTransactionWithPhysicalState()',
        ),
      );
      expect(reconcile.contains('GetAsyncKeyState(VK_LBUTTON)&0x8000'), isTrue);
      expect(reconcile.contains('EndOverlayClickShieldTransaction()'), isTrue);
    });
  });

  group('runner: VoiceHookReader 回调安全发布', () {
    test('Popup owner、try_lock、无 HWND 查询、release 不带 Left 位', () {
      final String header = compactCode(readerHeader);
      expect(
        header.contains(
          'uint32_tTryPublishOverlayClickShieldTransaction(HWNDgame,uint64_ttransaction_id,booldown);',
        ),
        isTrue,
      );
      final String body = compactCode(
        methodBody(
          readerSource,
          'uint32_t VoiceHookReader::TryPublishOverlayClickShieldTransaction(',
        ),
      );
      expect(body.contains('std::try_to_lock'), isTrue);
      expect(body.contains('std::lock_guard'), isFalse);
      expect(
        body.contains('IsWindow('),
        isFalse,
        reason: '与 attached 快路同一纪律：回调里不做 HWND 查询',
      );
      expect(body.contains('GetWindowThreadProcessId('), isFalse);
      expect(body.contains('kLookupShieldOwnerPopup'), isTrue);
      expect(body.contains('TryPublishLookupShieldRequestOnce('), isTrue);
      expect(
        body.contains('down?fushi_voice_hook::kLookupShieldButtonLeft:0u'),
        isTrue,
      );
      // 常规（会重试一秒）的发布入口仍把 Popup 列在白名单里——host 侧另一条路
      // （窗口线程）若将来要用，契约是同一个。
      final String regular = compactCode(
        methodBody(
          readerSource,
          'uint32_t VoiceHookReader::PublishLookupShieldTransaction(',
        ),
      );
      expect(
        regular.contains('casefushi_voice_hook::kLookupShieldOwnerPopup:'),
        isTrue,
      );
    });

    test('孤儿判定：try_lock、gate 关或槽位易主才算孤儿、写入中不算', () {
      final String header = compactCode(readerHeader);
      expect(
        header.contains(
          'boolOverlayClickShieldTransactionOrphaned(HWNDgame,uint64_ttransaction_id);',
        ),
        isTrue,
      );
      final String body = compactCode(
        methodBody(
          readerSource,
          'bool VoiceHookReader::OverlayClickShieldTransactionOrphaned(',
        ),
      );
      expect(body.contains('std::try_to_lock'), isTrue);
      expect(body.contains('std::lock_guard'), isFalse);
      expect(
        body.contains('if(!lock.owns_lock())returnfalse;'),
        isTrue,
        reason: '拿不到锁只是忙，不能判孤儿',
      );
      expect(body.contains('IsWindow('), isFalse);
      expect(body.contains('GetWindowThreadProcessId('), isFalse);
      expect(
        body.contains(
          'LookupGateLocked(st.header,false)!=VoiceHookLookupError::kNone){returntrue;}',
        ),
        isTrue,
        reason: '会话结束 release 永远发不出去',
      );
      expect(
        body.contains('if(!stable.valid)returnfalse;'),
        isTrue,
        reason: '写入中读不到稳定快照，下次再问',
      );
      expect(
        body.contains(
          'stable.owner_kind!=fushi_voice_hook::kLookupShieldOwnerPopup||stable.transaction_id!=transaction_id',
        ),
        isTrue,
        reason: '槽位已被别的 owner / 事务接管',
      );
    });
  });

  group('runner: 四类窗口的登记与撤销', () {
    test('桌面查词卡：Reveal / RevealStack 登记，ReleaseDismissHooks 撤销', () {
      final String reveal = compactCode(
        methodBody(cardSource, 'void GlobalLookupWindow::Reveal('),
      );
      expect(
        reveal.contains('fushi::RegisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
      final String stack = compactCode(
        methodBody(cardSource, 'void GlobalLookupWindow::RevealStack('),
      );
      expect(
        stack.contains('fushi::RegisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
      final String release = compactCode(
        methodBody(
          cardSource,
          'void GlobalLookupWindow::ReleaseDismissHooks()',
        ),
      );
      final int unregister = release.indexOf(
        'fushi::UnregisterOverlayClickShield(hwnd_);',
      );
      final int disarm = release.indexOf(
        'fushi::DisarmLowLevelMouseHook(hwnd_);',
      );
      expect(unregister, greaterThanOrEqualTo(0));
      expect(
        unregister,
        lessThan(disarm),
        reason: '先撤登记再 Disarm：Disarm 的宽限期卸载会问「还有没有登记」',
      );
    });

    test('hook 台词浮窗：Show 登记、Hide / WM_NCDESTROY 撤销、UpdateText 刷新', () {
      final String show = compactCode(
        methodBody(lyricSource, 'bool FloatingLyricWindow::Show(HWND owner)'),
      );
      final int visible = show.indexOf('visible_=true;');
      final int register = show.indexOf(
        'fushi::RegisterOverlayClickShield(hwnd_);',
      );
      expect(register, greaterThan(visible), reason: '窗口真的上屏之后才登记');
      final String hide = compactCode(
        methodBody(lyricSource, 'void FloatingLyricWindow::Hide()'),
      );
      expect(
        hide.contains('fushi::UnregisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
      final String handle = compactCode(
        methodBody(lyricSource, 'LRESULT FloatingLyricWindow::HandleMessage('),
      );
      expect(
        handle.contains('fushi::UnregisterOverlayClickShield(destroyed);'),
        isTrue,
        reason: 'HWND 值会被系统回收给别的窗口，销毁时必须撤登记',
      );
      final String update = compactCode(
        methodBody(lyricSource, 'void FloatingLyricWindow::UpdateText('),
      );
      expect(
        update.contains(
          'if(visible_&&OwnsLiveWindow()){fushi::RegisterOverlayClickShield(hwnd_);}',
        ),
        isTrue,
        reason: '每行台词刷新一次绑定的游戏 HWND（换局 / 重建主窗）',
      );
    });

    test('穿透工具条：Show 登记、Hide / 析构撤销', () {
      final String show = compactCode(
        methodBody(toolbarSource, 'bool HookToolbarWindow::Show('),
      );
      expect(
        show.contains('fushi::RegisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
      final String hide = compactCode(
        methodBody(toolbarSource, 'void HookToolbarWindow::Hide()'),
      );
      expect(
        hide.contains('fushi::UnregisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
      final String dtor = compactCode(
        methodBody(toolbarSource, 'HookToolbarWindow::~HookToolbarWindow()'),
      );
      expect(
        dtor.contains('fushi::UnregisterOverlayClickShield(hwnd_);'),
        isTrue,
      );
    });

    test('解析器按会话 pid 找游戏客户区窗，在任何覆盖窗口建出来之前装好', () {
      final String resolver = compactCode(
        methodBody(flutterWindowSource, 'HWND ResolveOverlayClickShieldGame()'),
      );
      expect(
        resolver.contains('VoiceHookReader::Instance().CurrentPid()'),
        isTrue,
      );
      expect(
        resolver.contains('FindProcessClientWindow(pid)'),
        isTrue,
        reason: '与 direct galCard 用同一条游戏窗口解析',
      );
      expect(
        resolver.contains('pid==0?nullptr:'),
        isTrue,
        reason: '没有会话必须返回 nullptr，让登记退化成空操作',
      );
      final String channel = compactCode(
        methodBody(
          flutterWindowSource,
          'void FlutterWindow::RegisterGalHookTextChannel()',
        ),
      );
      final int setResolver = channel.indexOf(
        'fushi::SetOverlayClickShieldGameResolver(&ResolveOverlayClickShieldGame);',
      );
      final int makeWindow = channel.indexOf(
        'gal_hook_text_window_=std::make_unique<FloatingLyricWindow>();',
      );
      expect(setResolver, greaterThanOrEqualTo(0));
      expect(setResolver, lessThan(makeWindow));
    });
  });

  group('注入侧：Popup owner 的接受面（本 PR 依赖的既有契约）', () {
    test('IPC 契约保留 Popup owner，且 host 白名单接受它', () {
      expect(
        ipcHeader.contains('constexpr uint32_t kLookupShieldOwnerPopup = 3u;'),
        isTrue,
      );
    });

    test('通用护盾 / HUNEX / smash 的激活判定不按 owner_kind 区分', () {
      final String generic = compactCode(
        methodBody(genericShield, 'bool GenericShieldRequestActiveForSurface('),
      );
      expect(
        generic.contains('owner_kind'),
        isFalse,
        reason: '通用护盾一旦开始按 owner 拒收，覆盖窗口请求就静默失效',
      );
      expect(generic.contains('kLookupShieldButtonLeft'), isTrue);
      final String hunex = compactCode(
        methodBody(
          hunexRuntime,
          'bool HunexGgeLookupShieldRequestActiveForLeft()',
        ),
      );
      expect(hunex.contains('owner_kind'), isFalse);
      expect(hunex.contains('GetCurrentProcessId()'), isTrue);
      final String smash = compactCode(
        methodBody(
          smashLookup,
          'bool SmashFzmediaLookupShieldRequestTargets(HWND game)',
        ),
      );
      expect(smash.contains('owner_kind'), isFalse);
    });
  });
}
