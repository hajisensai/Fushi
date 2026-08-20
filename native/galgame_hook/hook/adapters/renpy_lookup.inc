// Included from renpy_adapter.inc, which itself lives inside dll_main.cpp's anonymous
// namespace. **一行 #include 都不能有**：头文件里的 `namespace fushi_voice_hook` 会在
// 匿名命名空间里再开一个同名嵌套命名空间，把真正的 ::fushi_voice_hook 整个遮住，而报错
// 会全落在之后每个 adapter 里，一条都不指向肇事文件。
//
// ══ Ren'Py 游戏内查词传感器（字形几何 + 命中测试）══════════════════════════════════
//
// 与 KiriKiri 那条同构，宿主换成 CPython：
//   KiriKiri：注入 TJS → 读 TextRender.getCharacters() → 写 global → DLL 用
//             TVPExecuteExpression 读回。
//   Ren'Py ：注入 Python → 读 Text.get_layout().lines[i].glyphs → 写 __main__ 全局 →
//             DLL 用 Python C API 读回。
//
// 三条 Ren'Py 特有的事实（本机实测：Sakura Swim Club / Ren'Py 6.18.2.729 / Python 2.7 x86）：
//
// 1. **char_index 零换算**。该 Python 是 narrow(UCS-2) 构建（python27.dll 导出
//    PyUnicodeUCS2_*，不是 UCS4_*），Py_UNICODE 就是 UTF-16 code unit；ftfont 的
//    glyphs() 又逐 Py_UNICODE 产一个 Glyph（1:1）。于是 glyph 序号 == UTF-16 下标 ==
//    Dart String 下标，正是 LookupHitSlot.char_index 要的单位。
// 2. **坐标域天然正确**。renpy.display.draw.untranslate_mouse() 的输出就是游戏窗口
//    客户区物理像素，正是 lookup_overlay_geometry.h 要求的域（全屏 3 倍缩放下实测精确）。
//    KiriKiri 报的是 primaryLayer 坐标，只在图层铺满客户区时才等价；Ren'Py 不用绕这一圈。
// 3. **主线程接缝是官方扩展点**。renpy.config.periodic_callback 每帧在主事件循环的
//    PERIODIC 分支里调一次，不需要像 KiriKiri 那样 EnumWindows 猜线程 id。
//
// 线程纪律（BUG-1724 的教训，这里从第一行就守）：
//   * 后台线程只做两件事：**种回调**（纯赋值，不碰 Render/Layout）、**读回结果全局**。
//   * 所有引擎状态读取都在 periodic_callback 内，也就是引擎主线程上。
//   * Layout / Render / layout_cache 全部无锁。后台线程持 GIL 时主线程可能正停在
//     layout_cache_tick() 中间某个字节码边界上，读到的会是半构造的树。
//
// 为什么不 hook FreeType：ftfont.pyd 的导入表里**根本没有** FT_Render_Glyph（它走
// FT_Get_Glyph + FT_Glyph_To_Bitmap），而且 FreeType 只给 bitmap_left/top 这种 per-glyph
// bearing，屏幕落点是 textsupport 算出 glyph.x 之后才加上的。走那条路等于自己重写断行、
// ruby、RTL、描边，最后仍然拿不到 Text 在屏幕上的位置。

// Py_ssize_t：Win32 下是 int，x64 下是 __int64。只为 PyString_AsStringAndSize 用。
#if defined(_M_X64)
using PySsizeTCompat = __int64;
#else
using PySsizeTCompat = int;
#endif

// Python 2.7 的 C API 在 Windows 上是 __cdecl。只取本传感器真正用到的那几个。
using PyGILStateEnsureFn = int(__cdecl*)();
using PyGILStateReleaseFn = void(__cdecl*)(int);
using PyRunSimpleStringFn = int(__cdecl*)(const char*);
using PyIsInitializedFn = int(__cdecl*)();
using PyImportAddModuleFn = void*(__cdecl*)(const char*);
using PyModuleGetDictFn = void*(__cdecl*)(void*);
using PyDictGetItemStringFn = void*(__cdecl*)(void*, const char*);
using PyStringAsStringAndSizeFn = int(__cdecl*)(void*, char**, PySsizeTCompat*);
using PyIntAsLongFn = long(__cdecl*)(void*);
using PyErrClearFn = void(__cdecl*)();

PyGILStateEnsureFn g_py_gil_ensure = nullptr;
PyGILStateReleaseFn g_py_gil_release = nullptr;
PyRunSimpleStringFn g_py_run_simple = nullptr;
PyIsInitializedFn g_py_is_initialized = nullptr;
PyImportAddModuleFn g_py_import_add_module = nullptr;
PyModuleGetDictFn g_py_module_get_dict = nullptr;
PyDictGetItemStringFn g_py_dict_get_item = nullptr;
PyStringAsStringAndSizeFn g_py_string_as_string_and_size = nullptr;
PyIntAsLongFn g_py_int_as_long = nullptr;
PyErrClearFn g_py_err_clear = nullptr;

HMODULE g_renpy_python_module = nullptr;
// 0=未装 / 1=后台线程已登记「该装了」 / 2=回调已种下
volatile LONG g_renpy_lookup_state = 0;
// 上一次读回的 Python 侧命中序号；变了才发布一次 hit。
uint64_t g_renpy_last_hit_seq = 0;
// 宿主心跳。每轮 ProcessRenpyLookupTick +1 并写进 Python 全局 fushi_host_seq；
// Fushi 进程没了就不再递增，Python 侧据此自锁。与反方向的 fushi_lookup_seq
// （命中序号，Python 写 / native 读）是两个东西，别混。
uint64_t g_renpy_host_seq = 0;
bool g_renpy_last_button_down = false;
uint64_t g_renpy_submit_seq = 0;

// 找到已加载的 CPython。名字不写死成 python27.dll：Ren'Py 7/8 是 python3x，
// 而且有的发行版会改名。判据是「模块名像 pythonNN.dll 且导出 Py_IsInitialized」——
// 名字只用来缩小候选，**真正的准入是导出表**（照 CLAUDE.md「共享中间件不得仅凭 DLL 名启用」）。
HMODULE FindLoadedPythonModule() {
  HMODULE best = nullptr;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32,
                                         GetCurrentProcessId());
  if (snap == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W me = {0};
  me.dwSize = sizeof(me);
  if (Module32FirstW(snap, &me)) {
    do {
      const wchar_t* name = me.szModule;
      if (name == nullptr) continue;
      if (_wcsnicmp(name, L"python", 6) != 0) continue;
      if (GetProcAddress(me.hModule, "Py_IsInitialized") == nullptr) continue;
      if (GetProcAddress(me.hModule, "PyGILState_Ensure") == nullptr) continue;
      best = me.hModule;
      break;
    } while (Module32NextW(snap, &me));
  }
  CloseHandle(snap);
  return best;
}

// 解析全部需要的导出。**要么全有要么不装**——照 KiriKiri 那条的纪律：装一半比不装更糟，
// 半装状态下「没反应」与「引擎不支持」在真机上完全同形。
bool ResolveRenpyPythonApi(HMODULE python) {
  if (python == nullptr) return false;
  g_py_gil_ensure = reinterpret_cast<PyGILStateEnsureFn>(
      GetProcAddress(python, "PyGILState_Ensure"));
  g_py_gil_release = reinterpret_cast<PyGILStateReleaseFn>(
      GetProcAddress(python, "PyGILState_Release"));
  g_py_run_simple = reinterpret_cast<PyRunSimpleStringFn>(
      GetProcAddress(python, "PyRun_SimpleString"));
  g_py_is_initialized = reinterpret_cast<PyIsInitializedFn>(
      GetProcAddress(python, "Py_IsInitialized"));
  g_py_import_add_module = reinterpret_cast<PyImportAddModuleFn>(
      GetProcAddress(python, "PyImport_AddModule"));
  g_py_module_get_dict = reinterpret_cast<PyModuleGetDictFn>(
      GetProcAddress(python, "PyModule_GetDict"));
  g_py_dict_get_item = reinterpret_cast<PyDictGetItemStringFn>(
      GetProcAddress(python, "PyDict_GetItemString"));
  // Python 3 把 PyString_* 改成 PyBytes_*；两个名字都试，缺一不可。
  g_py_string_as_string_and_size =
      reinterpret_cast<PyStringAsStringAndSizeFn>(
          GetProcAddress(python, "PyString_AsStringAndSize"));
  if (g_py_string_as_string_and_size == nullptr) {
    g_py_string_as_string_and_size =
        reinterpret_cast<PyStringAsStringAndSizeFn>(
            GetProcAddress(python, "PyBytes_AsStringAndSize"));
  }
  g_py_int_as_long =
      reinterpret_cast<PyIntAsLongFn>(GetProcAddress(python, "PyInt_AsLong"));
  if (g_py_int_as_long == nullptr) {
    g_py_int_as_long =
        reinterpret_cast<PyIntAsLongFn>(GetProcAddress(python, "PyLong_AsLong"));
  }
  g_py_err_clear =
      reinterpret_cast<PyErrClearFn>(GetProcAddress(python, "PyErr_Clear"));
  return g_py_gil_ensure != nullptr && g_py_gil_release != nullptr &&
         g_py_run_simple != nullptr && g_py_is_initialized != nullptr &&
         g_py_import_add_module != nullptr && g_py_module_get_dict != nullptr &&
         g_py_dict_get_item != nullptr &&
         g_py_string_as_string_and_size != nullptr &&
         g_py_int_as_long != nullptr && g_py_err_clear != nullptr;
}

// 种进游戏进程的传感器。只在 __main__ 里定义函数并把 tick 挂上周期回调扩展点；
// 这一步**不读任何 Render/Layout**，所以在后台线程上执行是安全的。
//
// 结果一律以「扁平的 int + 一个 UTF-8 bytes」发布，不用 tuple/JSON：C 侧只需要
// PyInt_AsLong 与 PyString_AsStringAndSize 两个入口，跨 Python 2/3 都成立。
//
// ── 为什么挂载要链式（脚本尾部 _fs_cbs / fushi_prev_periodic 那段）────────────
// config.periodic_callback 是 Ren'Py **官方文档化**的扩展点（约 20Hz），游戏与 mod
// 拿它跑自动存档、计时器、状态机。裸赋值会把它们**永久**顶掉：本 DLL 不卸载，也没有
// 还原路径，症状是「游戏某个功能莫名不动了」，跟 Hibiki 完全对不上号。所以：
//   * Ren'Py 7.4+ 有复数列表 config.periodic_callbacks —— 优先 append，谁的槽都不动；
//   * 只有单数槽时才取旧值存进 fushi_prev_periodic，由 tick 在自己动手前先调一遍。
// 重复注入时旧值会是**上一次注入的** tick：它与本次是不同的函数对象，identity 比不
// 出来，必须拿覆盖前存下的 _fs_prev_tick 判，否则会把自己链进自己、每帧递归加深。
//
// ── 为什么脚本里要有 fushi_lookup_on 这道闸 ──────────────────────────────────
// 回调种下去就没有卸载路径。native 侧若在关查词时直接早退、不再写任何 Python 全局，
// 传感器仍会每帧跑 _fushi_find_render 全树遍历 + 每字形 2 次 Python 级 mapper 调用，
// 一直跑到游戏退出（实测 77 字形 ≈ 9k 次调用/秒常驻引擎主线程）。所以 native 每轮把
// 开关也写进来，ProcessRenpyLookupTick 里的 enable 判断排在那次赋值**之后**。
//
// ── 为什么光有 fushi_lookup_on 还不够：宿主心跳 fushi_host_seq ────────────────
// 开关只覆盖「用户关掉查词」。**Fushi 进程被直接杀掉**时 native 侧一轮都不再跑，开关
// 会永远停在最后写下的 1，Python 侧照样全速扫描到游戏退出——用户观感是「关了 Fushi
// 之后游戏还是卡」，且跟 Hibiki 完全对不上号。这与上面那条是同一类缺陷，只是触发面更窄。
// 所以 native 每轮再写一个单调递增的心跳，Python 侧连续 kFushiHostStallTicks 轮没见它
// 变就自锁早退；心跳一恢复递增立刻解锁（绝不能变成「Fushi 重连后查词永久不工作」）。
//
// 阈值的依据：worker 的轮询间隔是 200ms（adapter_registry.inc 的 PollDelayMs），
// Ren'Py 的 PERIODIC 约 20Hz、部分发行版按帧调到 60Hz+。所以正常间隔是 4~12 个 tick，
// 60 轮 = 20Hz 下 3 秒 / 60Hz 下 1 秒，对最坏的正常间隔仍有 5 倍余量。
// 误锁**无害且自愈**：任何携带新 submit 的赋值必然同时携带新心跳，而下面的心跳判定
// 排在自锁之前，于是解锁与那次 submit 落在同一个 tick 上——误锁只丢 hover 高亮的延迟，
// 丢不掉一次提交。
//
// 名字为什么不是 fushi_lookup_seq：那个名字**已经被占**——它是 Python 侧写、native 侧
// 读的命中序号（反方向）。同名两义正是这类 bug 的温床，所以另起 fushi_host_seq。
//
// PYSRC 是**窄**字符串字面量，MSVC 的 C2026 上限是 16380 字节（不是宽串那个 8190
// UTF-16 unit）。中文注释一字 3 字节，很容易吃光余量；写满了就插 `)PYSRC" "PYSRC(`
// 拆段，不要靠删注释腾地方。守卫见 tests/renpy_lookup_source_guard_test.py。
const char kRenpyLookupBootstrap[] = R"PYSRC(
import sys as _fs_sys

_fs_g = _fs_sys.modules['__main__'].__dict__
_fs_g.setdefault('fushi_lookup_ticks', 0)
_fs_g.setdefault('fushi_lookup_faults', 0)
_fs_g.setdefault('fushi_lookup_seq', 0)
_fs_g.setdefault('fushi_lookup_mainthread', 0)
_fs_g.setdefault('fushi_lookup_glyphs', 0)
_fs_g.setdefault('fushi_lookup_idx', -1)
_fs_g.setdefault('fushi_lookup_gx', 0)
_fs_g.setdefault('fushi_lookup_gy', 0)
_fs_g.setdefault('fushi_lookup_gw', 0)
_fs_g.setdefault('fushi_lookup_gh', 0)
_fs_g.setdefault('fushi_lookup_vw', 0)
_fs_g.setdefault('fushi_lookup_vh', 0)
_fs_g.setdefault('fushi_lookup_count', 0)
_fs_g.setdefault('fushi_lookup_line', b'')
# native 每轮写进来的总开关与宿主心跳。理由见文件上半的 C++ 注释。
_fs_g.setdefault('fushi_lookup_on', 0)
_fs_g.setdefault('fushi_host_seq', 0)
_fs_g.setdefault('fushi_host_last', -1)
_fs_g.setdefault('fushi_host_stall', 0)
# native 每轮写进来的光标状态：(客户区物理 x, y, submit 序号)
_fs_g.setdefault('fushi_cursor', (-1, -1, 0))
# native 每轮写进来的游戏窗口客户区尺寸（物理像素）。渲染器自报的 physical size 不可信。
_fs_g.setdefault('fushi_client', (0, 0))
_fs_g.setdefault('fushi_last_submit', 0)


def _fushi_find_render(node, target, ox, oy, depth):
    """在 Render 树里找 target 这个 displayable，返回它的累加偏移。

    Render.render_of 是「这个 Render 由哪些 displayable 产生」。children 的元素是
    (source, xo, yo, focus, main)，source 可能是 Render 也可能是 Surface —— 只有
    Render 才有 children，所以递归前要判。
    """
    if depth > 64:
        return None
    ro = getattr(node, 'render_of', None)
    if ro:
        for d in ro:
            if d is target:
                return (ox, oy)
    children = getattr(node, 'children', None)
    if not children:
        return None
    for ch in children:
        try:
            src = ch[0]
            cx = ch[1]
            cy = ch[2]
        except Exception:
            continue
        if getattr(src, 'children', None) is None and \
                getattr(src, 'render_of', None) is None:
            continue
        got = _fushi_find_render(src, target, ox + cx, oy + cy, depth + 1)
        if got is not None:
            return got
    return None


def _fushi_say_text(renpy):
    """拿当前对话框的 what Text。

    screen 名依赖游戏脚本：默认是 'say'，但同屏多个 say 时 character.py 会用
    say1/say2；自定义 Character(screen=...) 的游戏还会完全不同。这里轮询常见几个，
    拿不到就返回 None（**不猜**，宁可这一帧不采）。
    """
    screen = getattr(renpy.display, 'screen', None)
    if screen is None:
        return None
    layer = getattr(renpy.config, 'say_layer', 'screens')
    for name in ('say', 'say1', 'say2'):
        try:
            t = screen.get_widget(name, 'what', layer)
        except Exception:
            t = None
        if t is not None:
            return t
    return None


def _fushi_make_mapper(renpy, draw):
    """造一个「虚拟坐标 → 游戏窗口客户区物理像素」的换算器。

    三级，按可信度降序，并把实际用到的那一级记进 fushi_lookup_mapper 供诊断：

    1. draw.untranslate_mouse —— 引擎自己用来把鼠标换回虚拟坐标的**逆函数**，最准。
       但**只有 GLDraw 有**：软件渲染器 SWDraw 上没有这个属性（本机实测，
       AttributeError: 'SWDraw' object has no attribute 'untranslate_mouse'）。
    2. draw.virtual_box —— (x, y, w, h)，虚拟画面在物理窗口里的实际矩形，已含letterbox
       黑边偏移。配 config.screen_width/height 就能线性映射，GL/SW 都有。
    3. 纯比例 —— 只在前两者都没有时用，**不含黑边补偿**，会有偏移；仅作为不至于完全瞎掉
       的兜底，并且会在诊断里标出来，免得把它的误差当成几何算错。
    """
    fn = getattr(draw, 'untranslate_mouse', None)
    if callable(fn):
        _fs_g['fushi_lookup_mapper'] = 1
        return fn

    vw = float(getattr(renpy.config, 'screen_width', 0) or 0)
    vh = float(getattr(renpy.config, 'screen_height', 0) or 0)
    box = getattr(draw, 'virtual_box', None)
    if box is not None and vw > 0 and vh > 0:
        bx, by, bw, bh = box[0], box[1], box[2], box[3]
        sx = float(bw) / vw
        sy = float(bh) / vh

        def _map_box(x, y, _bx=bx, _by=by, _sx=sx, _sy=sy):
            return (_bx + x * _sx, _by + y * _sy)

        _fs_g['fushi_lookup_mapper'] = 2
        return _map_box

    # 第三级：用**游戏窗口客户区尺寸**（native 每轮写进 fushi_client）自己拟合。
    # Ren'Py 保持宽高比缩放并居中留黑边，规则就是 scale = min(cw/vw, ch/vh)、
    # 两侧各留一半余量。客户区尺寸是我们最确定的一个数（native 侧 GetClientRect 拿的），
    # 比向渲染器要 physical size 可靠——SWDraw 的 get_physical_size 实测返回的是**虚拟**
    # 尺寸（1280x720），照它算出来的比例是 1，坐标会整整差一个缩放。
    cw, ch = _fs_g.get('fushi_client', (0, 0))
    if vw > 0 and vh > 0 and cw > 0 and ch > 0:
        s = min(float(cw) / vw, float(ch) / vh)
        offx = (cw - vw * s) * 0.5
        offy = (ch - vh * s) * 0.5

        def _map_fit(x, y, _s=s, _ox=offx, _oy=offy):
            return (_ox + x * _s, _oy + y * _s)

        _fs_g['fushi_lookup_mapper'] = 3
        return _map_fit

    _fs_g['fushi_lookup_mapper'] = 0
    return None


def _fushi_physical_size(renpy, draw):
    """view_w/view_h：host 拿它定位与钳制卡片，域必须是**游戏窗口客户区物理像素**。

    优先用 native 送进来的客户区尺寸——那是 GetClientRect 的结果，没有歧义。
    渲染器自报的 physical size 不可信：SWDraw 实测返回虚拟尺寸。
    """
    cw, ch = _fs_g.get('fushi_client', (0, 0))
    if cw > 0 and ch > 0:
        return (int(cw), int(ch))
    ps = getattr(draw, 'get_physical_size', None)
    if callable(ps):
        try:
            w, h = ps()
            if w and h:
                return (int(w), int(h))
        except Exception:
            pass
    return (int(getattr(renpy.config, 'screen_width', 0) or 0),
            int(getattr(renpy.config, 'screen_height', 0) or 0))


def _fushi_lookup_scan():
    import renpy
    g = _fs_g
    draw = getattr(renpy.display, 'draw', None)
    if draw is None:
        return
    target = _fushi_say_text(renpy)
    if target is None:
        g['fushi_lookup_glyphs'] = 0
        if not g.get('fushi_reported_nosay'):
            g['fushi_reported_nosay'] = 1
            _fushi_report('no say widget; draw=%r screen=%r say_layer=%r' % (
                type(draw).__name__,
                getattr(renpy.display, 'screen', None) is not None,
                getattr(renpy.config, 'say_layer', None)))
        return

    root = getattr(renpy.display.render, 'screen_render', None)
    if root is None:
        iface = getattr(renpy.game, 'interface', None)
        root = getattr(iface, 'surftree', None) if iface is not None else None
    if root is None:
        return
    where = _fushi_find_render(root, target, 0, 0, 0)
    if where is None:
        g['fushi_lookup_glyphs'] = 0
        if not g.get('fushi_reported_norender'):
            g['fushi_reported_norender'] = 1
            _fushi_report('say widget found but not located in render tree; '
                          'root=%r has_children=%r' % (
                              type(root).__name__,
                              getattr(root, 'children', None) is not None))
        return
    ox, oy = where

    layout = target.get_layout()
    if layout is None:
        return
    xf = getattr(layout, 'xoffset', 0)
    yf = getattr(layout, 'yoffset', 0)

    mapper = _fushi_make_mapper(renpy, draw)
    if mapper is None:
        if not g.get('fushi_reported_nomapper'):
            g['fushi_reported_nomapper'] = 1
            _fushi_report('no virtual->physical mapper on %s' % type(draw).__name__)
        return

    chars = []
    rects = []
    for line in layout.lines:
        for gl in line.glyphs:
            code = gl.character
            if code == 0:
                # SpaceSegment / DisplayableSegment 产的占位 glyph，没有字符。
                continue
            vx = ox + gl.x + xf
            vy = oy + line.y + yf
            adv = gl.advance if gl.advance else gl.width
            px0, py0 = mapper(vx, vy)
            px1, py1 = mapper(vx + adv, vy + line.height)
            chars.append(unichr(code) if _fs_sys.version_info[0] < 3 else chr(code))
            rects.append((int(px0), int(py0), int(px1 - px0), int(py1 - py0)))

    g['fushi_lookup_glyphs'] = len(rects)
    if not g.get('fushi_reported_first'):
        g['fushi_reported_first'] = 1
        _fushi_report('first scan ok: glyphs=%d origin=(%d,%d) offset=(%r,%r) '
                      'mapper=%d draw=%s virt=(%r,%r) client=%r '
                      'get_physical=%r virtual_box=%r sample=%r' % (
                          len(rects), ox, oy, xf, yf,
                          g.get('fushi_lookup_mapper', -1),
                          type(draw).__name__,
                          getattr(renpy.config, 'screen_width', None),
                          getattr(renpy.config, 'screen_height', None),
                          g.get('fushi_client'),
                          (draw.get_physical_size()
                           if hasattr(draw, 'get_physical_size') else None),
                          getattr(draw, 'virtual_box', None),
                          rects[:3] if rects else None))
    if not rects:
        return
    line_text = u''.join(chars)
    g['fushi_lookup_line'] = line_text.encode('utf-8')
    g['fushi_lookup_count'] = len(line_text)

    pw, ph = _fushi_physical_size(renpy, draw)
    g['fushi_lookup_vw'] = int(pw)
    g['fushi_lookup_vh'] = int(ph)

    cx, cy, submit = g.get('fushi_cursor', (-1, -1, 0))
    if cx < 0:
        return

    hit = -1
    for i, r in enumerate(rects):
        if r[0] <= cx < r[0] + r[2] and r[1] <= cy < r[1] + r[3]:
            hit = i
            break

    # hover：命中哪个字**每帧都算**，但不写命中槽（那是 submit 的事，写了会让后到的
    # hover 覆盖尚未被 host 消费的 submit）。它的用处有两个：
    #   * 真机验证时不需要真按键就能把「几何 + 命中测试」这段验穿——合成输入在本机
    #     只能移动光标（SetCursorPos），按不下真键，GetAsyncKeyState 永远看不到边沿；
    #   * 换游戏排障时能直接看出是「没采到字形」还是「采到了但坐标域不对」。
    if hit != g.get('fushi_hover_idx', -2):
        g['fushi_hover_idx'] = hit
        n = g.get('fushi_hover_reports', 0)
        if n < 6:
            g['fushi_hover_reports'] = n + 1
            _fushi_report('hover cursor=(%d,%d) idx=%d rect=%r char=%r' % (
                cx, cy, hit,
                rects[hit] if hit >= 0 else None,
                chars[hit] if hit >= 0 else None))

    if submit == g.get('fushi_last_submit', 0):
        return
    g['fushi_last_submit'] = submit
    if hit < 0:
        return
    r = rects[hit]
    g['fushi_lookup_idx'] = hit
    g['fushi_lookup_gx'] = r[0]
    g['fushi_lookup_gy'] = r[1]
    g['fushi_lookup_gw'] = r[2]
    g['fushi_lookup_gh'] = r[3]
    g['fushi_lookup_seq'] = g['fushi_lookup_seq'] + 1


def _fushi_report(text):
    """把诊断写到 %TEMP%，**限量**。

    hook 侧没有通用日志出口，而 lookup_diag 只有位、说不出"为什么没采到"。这条通道只在
    出错或首次成功时写，绝不每帧写——传感器跑在引擎主线程上，每帧碰磁盘就是掉帧。
    """
    g = _fs_g
    n = g.get('fushi_report_count', 0)
    if n >= 8:
        return
    g['fushi_report_count'] = n + 1
    try:
        import os
        path = os.path.join(os.environ.get('TEMP', '.'),
                            'fushi_renpy_lookup_debug.log')
        f = open(path, 'ab')
        try:
            f.write(text.encode('utf-8', 'replace') + b'\n')
        finally:
            f.close()
    except Exception:
        pass


def _fushi_lookup_tick():
    g = _fs_g
    # 游戏自己的周期回调先原样跑一遍。**不包 try**：包起来会改掉它原本的语义。
    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    # 关闸排在链完旧回调之后：游戏的周期逻辑与查词开关无关，一帧都不能少调。
    if not g.get('fushi_lookup_on', 0):
        return
    # 宿主心跳自锁（Fushi 被杀掉时开关会停在 1）。判定排在自锁之前 = 立刻解锁。
    seq = g.get('fushi_host_seq', 0)
    if seq != g.get('fushi_host_last', -1):
        g['fushi_host_last'] = seq
        g['fushi_host_stall'] = 0
    else:
        stall = g.get('fushi_host_stall', 0) + 1
        g['fushi_host_stall'] = stall
        if stall >= 60:
            return
    g['fushi_lookup_ticks'] = g['fushi_lookup_ticks'] + 1
    if g['fushi_lookup_mainthread'] == 0:
        try:
            import threading
            if threading.current_thread().name == 'MainThread':
                g['fushi_lookup_mainthread'] = 1
        except Exception:
            pass
    try:
        _fushi_lookup_scan()
    except Exception:
        # 传感器绝不把异常抛回引擎的事件循环——那会让游戏自己崩在 PERIODIC 分支里。
        g['fushi_lookup_faults'] = g['fushi_lookup_faults'] + 1
        try:
            import traceback
            _fushi_report('=== scan fault ===\n' + traceback.format_exc())
        except Exception:
            pass


# 上一次注入留下的 tick（重复注入时才有）。**不能**读 _fushi_lookup_tick：上面那个
# def 已经把本次的新函数绑进同一个 __main__ 全局字典了，读回来的是自己。所以另设一个
# 只由下面这行显式写的槽 fushi_installed_tick，它才真的是"上一次"。
_fs_prev_tick = _fs_g.get('fushi_installed_tick')
_fs_g['fushi_installed_tick'] = _fushi_lookup_tick

_fs_g['_fushi_lookup_tick'] = _fushi_lookup_tick
_fs_g['_fushi_lookup_scan'] = _fushi_lookup_scan
_fs_g['_fushi_find_render'] = _fushi_find_render
_fs_g['_fushi_say_text'] = _fushi_say_text

import renpy.config as _fs_config

# 链式挂载：绝不裸赋值顶掉游戏自己的回调。完整理由见文件上半的 C++ 注释。
_fs_cbs = getattr(_fs_config, 'periodic_callbacks', None)
if isinstance(_fs_cbs, list):
    if _fs_prev_tick is not None and _fs_prev_tick in _fs_cbs:
        _fs_cbs.remove(_fs_prev_tick)
    if _fushi_lookup_tick not in _fs_cbs:
        _fs_cbs.append(_fushi_lookup_tick)
    _fs_g['fushi_prev_periodic'] = None
else:
    _fs_prev = getattr(_fs_config, 'periodic_callback', None)
    if _fs_prev is _fushi_lookup_tick or _fs_prev is _fs_prev_tick:
        _fs_prev = _fs_g.get('fushi_prev_periodic')
    _fs_g['fushi_prev_periodic'] = _fs_prev
    _fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

// 读一个 __main__ 全局整数。调用方必须已持 GIL。
long ReadRenpyGlobalInt(void* main_dict, const char* name, long fallback) {
  if (main_dict == nullptr || g_py_dict_get_item == nullptr) return fallback;
  void* value = g_py_dict_get_item(main_dict, name);
  if (value == nullptr) return fallback;
  const long result = g_py_int_as_long(value);
  if (g_py_err_clear != nullptr) g_py_err_clear();
  return result;
}

// 读一个 __main__ 全局 bytes（Python 侧已 encode('utf-8')）。调用方必须已持 GIL。
// 返回的指针指向 Python 对象内部缓冲，调用方必须在释放 GIL 之前拷走。
const char* ReadRenpyGlobalBytes(void* main_dict, const char* name,
                                 size_t* out_len) {
  if (out_len != nullptr) *out_len = 0;
  if (main_dict == nullptr || g_py_dict_get_item == nullptr) return nullptr;
  void* value = g_py_dict_get_item(main_dict, name);
  if (value == nullptr) return nullptr;
  char* buffer = nullptr;
  PySsizeTCompat length = 0;
  if (g_py_string_as_string_and_size(value, &buffer, &length) != 0) {
    if (g_py_err_clear != nullptr) g_py_err_clear();
    return nullptr;
  }
  if (buffer == nullptr || length <= 0) return nullptr;
  if (out_len != nullptr) *out_len = static_cast<size_t>(length);
  return buffer;
}

// 把命中写进共享内存的单槽。写序与 KiriKiri 那条逐字一致：先把 seq 清 0，填 payload，
// **最后**发布新 seq，再推进 lookup_hit_count。读侧靠这个顺序判「这一槽是不是完整的」。
void PublishRenpyLookupHit(uint32_t char_index, uint32_t char_count,
                           int32_t gx, int32_t gy, int32_t gw, int32_t gh,
                           int32_t vw, int32_t vh, const char* line_utf8,
                           size_t line_bytes) {
  if (g_header == nullptr) return;
  fushi_voice_hook::LookupHitSlot* slot = fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr) return;
  const uint64_t next =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64*>(&g_header->lookup_hit_count), 0,
          0)) +
      1u;
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&slot->seq), 0);
  slot->char_index = char_index;
  slot->char_count = char_count;
  slot->glyph_x = gx;
  slot->glyph_y = gy;
  slot->glyph_w = gw;
  slot->glyph_h = gh;
  slot->view_w = vw;
  slot->view_h = vh;
  slot->flags = fushi_voice_hook::kLookupHitFlagSubmit;
  size_t copy = line_bytes;
  if (copy > fushi_voice_hook::kLookupLineBytes) {
    copy = fushi_voice_hook::kLookupLineBytes;
  }
  if (line_utf8 != nullptr && copy > 0) {
    memcpy(slot->line_utf8, line_utf8, copy);
  }
  slot->line_bytes = static_cast<uint32_t>(copy);
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&slot->seq),
                        static_cast<LONG64>(next));
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&g_header->lookup_hit_count),
      static_cast<LONG64>(next));
  g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  g_header->lookup_diag |= fushi_voice_hook::kLookupDiagHitSubmitted;
}

// 后台线程只登记「该装了」，一个引擎调用都不做。真正的安装在 ProcessRenpyLookupTick
// 里做——那里同样是后台线程，但只跑 bootstrap（纯赋值），不碰 Render/Layout。
void PollRenpyLookupInstall() {
  if (g_stop || g_header == nullptr) return;
  if (!fushi_voice_hook::HasLookupRegion(g_header)) return;
  if (g_header->lookup_enabled == 0) return;
  if (InterlockedCompareExchange(&g_renpy_lookup_state, 0, 0) != 0) return;
  InterlockedExchange(&g_renpy_lookup_state, 1);
}

// 种下 periodic_callback。只在「已登记」状态下跑一次。
bool InstallRenpyLookupSensor() {
  if (InterlockedCompareExchange(&g_renpy_lookup_state, 0, 0) != 1) return false;
  if (g_renpy_python_module == nullptr) {
    g_renpy_python_module = FindLoadedPythonModule();
  }
  if (g_renpy_python_module == nullptr) return false;
  if (!ResolveRenpyPythonApi(g_renpy_python_module)) {
    // 导出缺一就整体不装：半装状态下「没反应」与「引擎不支持」在真机上完全同形。
    return false;
  }
  if (g_py_is_initialized() == 0) return false;  // 解释器还没起来，下一轮再试

  const int gil = g_py_gil_ensure();
  const int rc = g_py_run_simple(kRenpyLookupBootstrap);
  if (rc != 0 && g_py_err_clear != nullptr) g_py_err_clear();
  g_py_gil_release(gil);
  if (rc != 0) return false;

  InterlockedExchange(&g_renpy_lookup_state, 2);
  if (g_header != nullptr) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorInstalled;
    // Ren'Py 的卡片没有引擎内图层可挂，走通用分层窗口呈现器——所以这里**不**认领。
    // （KiriKiri 才调 ClaimLookupPresenter()。）
  }
  return true;
}

// 每轮（后台线程）：把光标状态写进 Python 全局，再读回上一帧算好的命中。
// 全程持 GIL；只读/写 __main__ 里的普通 int 与 bytes，不碰任何引擎对象。
void ProcessRenpyLookupTick() {
  if (g_stop || g_header == nullptr) return;
  if (!fushi_voice_hook::HasLookupRegion(g_header)) return;

  // lookup_enabled 不能在这里就 return：传感器一旦种进游戏进程就**没有卸载路径**
  // （DLL 不卸载，config.periodic_callback / periodic_callbacks 只能被覆盖或摘除，
  // 而摘除同样得由主线程做）。早退等于停止写任何 Python 全局，Python 侧的 tick 于是
  // 继续每帧跑 _fushi_find_render 全树遍历 + 每字形 2 次 Python 级 mapper 调用，
  // 一直跑到游戏退出（实测 77 字形 ≈ 9k 次调用/秒常驻引擎主线程）。
  // 所以：关的时候也要走到下面那次赋值，把 fushi_lookup_on 写 0，让 Python 侧早退。
  const bool lookup_on = g_header->lookup_enabled != 0;

  if (InterlockedCompareExchange(&g_renpy_lookup_state, 0, 0) == 1) {
    // 还没种下去：关着就别装（装了才需要关闸）。
    if (lookup_on) InstallRenpyLookupSensor();
    return;
  }
  if (InterlockedCompareExchange(&g_renpy_lookup_state, 0, 0) != 2) return;

  // 光标 → 游戏窗口客户区物理像素。用 Win32 而不是 hook 引擎输入：一来引擎无关，
  // 二来 Ren'Py 的事件在 Python 层，从 native 拦它反而更脆。
  POINT cursor = {0, 0};
  bool has_cursor = false;
  int client_w = 0;
  int client_h = 0;
  if (lookup_on) {
    HWND game = FindGameMainWindow();
    if (game != nullptr) {
      RECT client = {};
      if (GetClientRect(game, &client)) {
        client_w = client.right - client.left;
        client_h = client.bottom - client.top;
      }
      if (GetCursorPos(&cursor) && ScreenToClient(game, &cursor)) {
        has_cursor = true;
      }
    }
  }
  // 提交触发用 **Shift**，不用左键。
  //
  // 这不是口味问题：Ren'Py 里左键属于引擎——点一下就推进剧情、重建 say screen，
  // 于是「点字查词」和「往下读」是同一个动作，必然打架（真机实测：一次点击把
  // text_writes 从 27 顶到 31，被查的那句已经不在了）。KiriKiri 那边能用点击是因为
  // 卡片层挂进了引擎输入树、把点击吃掉了；Ren'Py 这条走的是进程内分层窗口，吃不掉。
  // KiriKiri 的键盘钩子本来也有 Shift 提交，这里与之对齐。
  //
  // 边沿触发：按下的那一帧才 +1，按住不该反复提交。
  const bool down =
      lookup_on && (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  if (down && !g_renpy_last_button_down) ++g_renpy_submit_seq;
  g_renpy_last_button_down = down;

  // 心跳每轮都递增，包括关着查词的那些轮：Python 侧的自锁判的是「宿主还在不在」，
  // 不是「查词开没开」——两件事混在一起就会在关查词期间误锁，再开时白等一次超时。
  ++g_renpy_host_seq;

  const int gil = g_py_gil_ensure();
  // 320 不是随手写的：最坏情况 40(前缀) + 21(on) + 39(host_seq) + 62(cursor) +
  // 41(client) = 203 字节。_TRUNCATE 截断出来的是**语法错误的 Python**，会被
  // PyErr_Clear 静静吞掉，然后传感器就永远收不到新光标——所以这里要留够余量。
  char assign[320] = {0};
  _snprintf_s(assign, sizeof(assign), _TRUNCATE,
              "_m=__import__('sys').modules['__main__'];"
              "_m.fushi_lookup_on=%d;"
              "_m.fushi_host_seq=%llu;"
              "_m.fushi_cursor=(%d,%d,%llu);_m.fushi_client=(%d,%d)",
              lookup_on ? 1 : 0,
              static_cast<unsigned long long>(g_renpy_host_seq),
              has_cursor ? static_cast<int>(cursor.x) : -1,
              has_cursor ? static_cast<int>(cursor.y) : -1,
              static_cast<unsigned long long>(g_renpy_submit_seq), client_w,
              client_h);
  if (g_py_run_simple(assign) != 0 && g_py_err_clear != nullptr) {
    g_py_err_clear();
  }
  // 关闸写完才早退。顺序反了这条修复就完全不存在——那正是原来的形态。
  if (!lookup_on) {
    g_py_gil_release(gil);
    return;
  }

  void* main_module = g_py_import_add_module("__main__");
  void* main_dict =
      main_module != nullptr ? g_py_module_get_dict(main_module) : nullptr;
  if (main_dict == nullptr) {
    g_py_gil_release(gil);
    return;
  }

  const long ticks = ReadRenpyGlobalInt(main_dict, "fushi_lookup_ticks", 0);
  const long on_main = ReadRenpyGlobalInt(main_dict, "fushi_lookup_mainthread", 0);
  const long glyphs = ReadRenpyGlobalInt(main_dict, "fushi_lookup_glyphs", 0);
  const long faults = ReadRenpyGlobalInt(main_dict, "fushi_lookup_faults", 0);
  const uint64_t hit_seq = static_cast<uint64_t>(
      ReadRenpyGlobalInt(main_dict, "fushi_lookup_seq", 0));

  // 诊断位按「真的发生了什么」置：回调真在主线程上跑过、真采到过字形。
  if (ticks > 0 && on_main != 0) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagExpressionReady;
  }
  if (glyphs > 0) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  }
  if (faults > 0) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorFault;
  }

  if (hit_seq != 0 && hit_seq != g_renpy_last_hit_seq) {
    const long idx = ReadRenpyGlobalInt(main_dict, "fushi_lookup_idx", -1);
    const long count = ReadRenpyGlobalInt(main_dict, "fushi_lookup_count", 0);
    const long gx = ReadRenpyGlobalInt(main_dict, "fushi_lookup_gx", 0);
    const long gy = ReadRenpyGlobalInt(main_dict, "fushi_lookup_gy", 0);
    const long gw = ReadRenpyGlobalInt(main_dict, "fushi_lookup_gw", 0);
    const long gh = ReadRenpyGlobalInt(main_dict, "fushi_lookup_gh", 0);
    const long vw = ReadRenpyGlobalInt(main_dict, "fushi_lookup_vw", 0);
    const long vh = ReadRenpyGlobalInt(main_dict, "fushi_lookup_vh", 0);
    size_t line_bytes = 0;
    const char* line = ReadRenpyGlobalBytes(main_dict, "fushi_lookup_line",
                                            &line_bytes);
    if (idx >= 0 && count > 0 && idx < count) {
      // 必须在释放 GIL 之前拷走：line 指向 Python 对象内部缓冲。
      PublishRenpyLookupHit(static_cast<uint32_t>(idx),
                            static_cast<uint32_t>(count),
                            static_cast<int32_t>(gx), static_cast<int32_t>(gy),
                            static_cast<int32_t>(gw), static_cast<int32_t>(gh),
                            static_cast<int32_t>(vw), static_cast<int32_t>(vh),
                            line, line_bytes);
      g_renpy_last_hit_seq = hit_seq;
    }
  }
  g_py_gil_release(gil);
}
