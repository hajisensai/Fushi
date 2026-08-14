#!/usr/bin/env python3
"""游戏内查词 replay 的**变异实测**工具（手动跑，不进 CTest）。

`lookup_session_replay_test.cpp` + `fixtures/kirikiri_lookup_replay.tsv` 是一张黄金表。
黄金表最容易烂的方式不是写错，而是**空**：判据被放宽之后它照样绿，谁都看不出来。所以每次
改动那个 replay 或它的 fixture，都必须回来跑一遍本工具，确认每条不变量删掉之后测试真的红。

用法（Windows，需要 MSVC 环境；先跑 vcvars64.bat 或在 Developer Prompt 里）：

    python tests/mutate_lookup_replay.py

它会把每个变异体写进 %TEMP%\\galhook_lookup_mutants，逐个编译并对同一份 fixture 运行，
打印「基线 + 每个变异体的退出码与首几行差异」。**基线必须 0，每个变异体必须非 0。**
任何一个变异体是绿的，就说明对应那条不变量在黄金表里没有被真正约束。

每个变异体对应一条会红的历史或潜在故障：
  M1 迟到帧不丢    → 连点两下把上一个词的卡片贴出来（串卡）
  M2 未开启也发布  → 开关形同虚设，注入侧在用户没开时就写共享内存
  M3 卡片外也转发  → 吃掉游戏自己的点击
  M4 会话不清理    → 上一局的卡片贴到这一局
  M5 不过尺寸闸门  → 按跨进程不可信的 width/height 盲拷（越界写）
  M6 收卡判据退回单 seq → **真实发生过的事故**：收卡帧被自己刚 present 的 seq 挡成陈旧帧
  M7 收卡靠 width==0 判 → 魔法编码把 host 投的废帧误当收卡，卡片莫名消失
"""

from __future__ import annotations

import io
import os
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SOURCE = HERE / "lookup_session_replay_test.cpp"
FIXTURE = HERE / "fixtures" / "kirikiri_lookup_replay.tsv"
OUT = pathlib.Path(os.environ.get("TEMP", "/tmp")) / "galhook_lookup_mutants"

# (名字, 原文, 替换)。原文必须逐字节存在，否则直接报错——变异锚点悄悄失配 = 变异实测
# 变成空跑，比不跑更糟。
MUTANTS: list[tuple[str, str, str]] = [
    (
        "M1_late_frame_not_dropped",
        "      if (!ShouldApplyLookupFrame(seq, frame->hit_seq, frame->flags,\n"
        "                                  presented_seq_, current_any_hit,\n"
        "                                  hook_submit_hit_seq_)) {",
        "      if (!ShouldApplyLookupFrame(seq, hook_submit_hit_seq_, frame->flags,\n"
        "                                  presented_seq_, current_any_hit,\n"
        "                                  hook_submit_hit_seq_)) {",
    ),
    (
        "M2_publish_hit_while_disabled",
        "    if (h->lookup_enabled == 0) {\n"
        "      ++counters_.hits_suppressed_while_disabled;\n"
        "      return;\n    }",
        "    if (false) {\n"
        "      ++counters_.hits_suppressed_while_disabled;\n"
        "      return;\n    }",
    ),
    (
        "M3_forward_outside_inputs",
        "    if (h->lookup_enabled == 0 || !inside) {",
        "    if (h->lookup_enabled == 0 && !inside) {",
    ),
    (
        "M4_skip_session_cleanup",
        "    memset(mapping_->lookup_region(), 0,\n"
        "           static_cast<size_t>(mapping_->lookup_bytes));",
        "",
    ),
    (
        "M5_skip_frame_size_gate",
        "    if (!IsLookupFrameSane(h, best) ||\n"
        "        static_cast<uint32_t>(best_seq % h->lookup_frame_count) != best_index) {",
        "    if (static_cast<uint32_t>(best_seq % h->lookup_frame_count) != best_index) {",
    ),
    (
        # 历史事故的精确复刻：一个号既当发布序又当"回应哪次 hit"。
        "M6_single_seq_regression",
        "      const uint64_t seq = frame->seq;",
        "      const uint64_t seq = frame->hit_seq;",
    ),
    (
        "M7_dismiss_by_zero_width",
        "    if ((best->flags & kLookupFrameDismiss) != 0) {",
        "    if (best->width == 0) {",
    ),
]

CL_FLAGS = [
    "/nologo",
    "/utf-8",
    "/std:c++17",
    "/W4",
    "/WX",
    "/EHsc",
    "/DUNICODE",
    "/D_UNICODE",
    "/DNOMINMAX",
    "/DWIN32_LEAN_AND_MEAN",
    f"/I{ROOT / 'include'}",
]


def build_and_run(name: str, source_path: pathlib.Path) -> tuple[int, str]:
    exe = OUT / f"{name}.exe"
    build = _run_capture(["cl", *CL_FLAGS, str(source_path), f"/Fe:{exe}"], cwd=OUT)
    if build[0] != 0:
        return build
    return _run_capture([str(exe), str(FIXTURE)], cwd=None)


def _run_capture(argv: list[str], cwd: pathlib.Path | None) -> tuple[int, str]:
    """跑一条命令并把 stdout+stderr 合成一个字符串。

    **必须显式指定 utf-8 + errors="replace"**：中文 Windows 上 Python 的 text 模式
    默认按 GBK 解码子进程输出，而变异体的失败信息里全是中文断言 —— 一旦某个变异体
    真的红了，解码就抛 UnicodeDecodeError，整个工具在"第一个变异体失败"的那一刻崩掉。
    也就是说：**工具只在所有变异体都没红的时候才跑得完**，恰好把它唯一要证明的事情
    （变异体会红）变成它的崩溃条件。errors="replace" 是第二道保险，避免子进程吐出
    非 UTF-8 字节（MSVC 的部分诊断走系统页）时再炸一次。
    """
    proc = subprocess.run(
        argv,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def main() -> int:
    if shutil.which("cl") is None:
        print("需要 MSVC 的 cl.exe：先跑 vcvars64.bat 或在 Developer Prompt 里执行。")
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    text = io.open(SOURCE, encoding="utf-8").read()

    baseline = OUT / "baseline.cpp"
    io.open(baseline, "w", encoding="utf-8", newline="\n").write(text)
    code, output = build_and_run("baseline", baseline)
    print(f"[baseline] exit={code}")
    for line in output.splitlines()[:4]:
        print("   ", line)
    failures = 0
    if code != 0:
        print("!! 基线就是红的，先修 replay 本身再谈变异实测")
        failures += 1

    for name, old, new in MUTANTS:
        if old not in text:
            print(f"[{name}] !! 变异锚点已失配，请更新本工具（否则变异实测是空跑）")
            failures += 1
            continue
        path = OUT / f"{name}.cpp"
        io.open(path, "w", encoding="utf-8", newline="\n").write(
            text.replace(old, new, 1)
        )
        code, output = build_and_run(name, path)
        print(f"[{name}] exit={code}")
        for line in output.splitlines()[:5]:
            print("   ", line)
        if code == 0:
            print(f"!! {name} 没红 —— 这条不变量在黄金表里没有被真正约束")
            failures += 1
    print("变异实测通过" if failures == 0 else f"变异实测失败：{failures} 项")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
