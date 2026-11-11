"""在被控端拉起 galgame 真机驱动并按文件协议收发指令。

驱动是 `fushi/integration_test/gal_realgame_driver_itest.dart` 打成的 Debug 版
fushi.exe（见 build_packages.ps1）。协议（驱动侧已实现，这里只做客户端）：

* 我们写 `GALDRIVER_DIR/cmd.txt`（一行一条指令），驱动读完即删；
* 驱动每执行完一条，把结果追加到 `out.txt`，再把累计序号写进 `done.txt`；
* 截图落 `shot_<n>.png`。

数据隔离：驱动进程带 `FUSHI_TEST_ROOT=<workdir>/test-root`，app 的 documents /
support / temp 全部落在测试根，不碰志愿者真实的 Fushi 数据；`FUSHI_TEST_HIDDEN=1`
让测试宿主窗口不抢前台、停在屏幕外。需要词典时用 seed_* 把真实数据目录复制进测试根。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

OUT_TAIL_CHARS = 4000


class GalDriverError(RuntimeError):
    pass


@dataclass
class GalDriverHost:
    """一个被控端最多一个驱动进程；所有方法线程安全。"""

    exe: Optional[Path]
    workdir: Path
    # 额外的启动参数，测试用假驱动时传脚本路径。
    exe_args: list[str] = field(default_factory=list)
    _proc: Optional[subprocess.Popen] = field(default=None, init=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False)
    _log_handle: Optional[object] = field(default=None, init=False, repr=False)
    # 本次驱动进程启动以来已发出的指令条数（与驱动 done.txt 的序号对齐）。
    _sent: int = field(default=0, init=False, repr=False)

    @property
    def driver_dir(self) -> Path:
        return self.workdir / "galdriver"

    @property
    def test_root(self) -> Path:
        return self.workdir / "test-root"

    @property
    def stdout_log(self) -> Path:
        return self.workdir / "galdriver_stdout.log"

    # ── 状态 ────────────────────────────────────────────────────────────────

    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _done_seq(self) -> Optional[str]:
        try:
            return (self.driver_dir / "done.txt").read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return None
        except OSError:
            # 驱动正在写；视为未变化，下一轮再读。
            return None

    def _out_size(self) -> int:
        try:
            return (self.driver_dir / "out.txt").stat().st_size
        except FileNotFoundError:
            return 0

    def _read_out(self, offset: int) -> str:
        path = self.driver_dir / "out.txt"
        try:
            with path.open("rb") as fh:
                fh.seek(offset)
                return fh.read().decode("utf-8", errors="replace")
        except FileNotFoundError:
            return ""

    def _shots(self) -> set[str]:
        if not self.driver_dir.exists():
            return set()
        return {p.name for p in self.driver_dir.glob("shot_*.png")}

    def _stdout_tail(self, chars: int = 3000) -> str:
        try:
            text = self.stdout_log.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return ""
        return text[-chars:]

    def status(self) -> dict[str, object]:
        out = self._read_out(max(0, self._out_size() - OUT_TAIL_CHARS))
        return {
            "exe": str(self.exe) if self.exe else None,
            "exe_exists": bool(self.exe and self.exe.exists()),
            "running": self.running(),
            "pid": self._proc.pid if self._proc else None,
            "exit_code": None if self._proc is None else self._proc.poll(),
            "driver_dir": str(self.driver_dir),
            "test_root": str(self.test_root),
            "done_seq": self._done_seq(),
            "out_tail": out[-OUT_TAIL_CHARS:],
            "shots": sorted(self._shots()),
        }

    # ── 启停 ────────────────────────────────────────────────────────────────

    def start(
        self,
        *,
        seed_support_dir: Optional[str] = None,
        seed_documents_dir: Optional[str] = None,
        reset_test_root: bool = False,
        hidden: bool = True,
        extra_env: Optional[dict[str, str]] = None,
        ready_timeout_s: float = 180.0,
    ) -> dict[str, object]:
        with self._lock:
            if self.running():
                raise GalDriverError(f"驱动已在运行 pid={self._proc.pid}；先 galdriver_stop")
            if self.exe is None or not self.exe.exists():
                raise GalDriverError(
                    f"找不到驱动 exe: {self.exe}；用 put_file 推送 driver 目录或检查 agent.json"
                )
            if reset_test_root and self.test_root.exists():
                shutil.rmtree(self.test_root)
            self.driver_dir.mkdir(parents=True, exist_ok=True)
            for stale in ("cmd.txt", "done.txt"):
                (self.driver_dir / stale).unlink(missing_ok=True)
            out = self.driver_dir / "out.txt"
            if out.exists():
                out.replace(self.driver_dir / "out.prev.txt")
            seeded = self._seed(seed_support_dir, seed_documents_dir)

            env = dict(os.environ)
            root = self.test_root
            env.update(
                {
                    "GALDRIVER_DIR": str(self.driver_dir),
                    "FUSHI_TEST_ROOT": str(root),
                    "FUSHI_TEST_RUN_ID": f"remote-{int(time.time())}",
                    "FUSHI_WEBVIEW2_USER_DATA_FOLDER": str(root / "webview2-profile"),
                }
            )
            if hidden:
                env["FUSHI_TEST_HIDDEN"] = "1"
            else:
                env.pop("FUSHI_TEST_HIDDEN", None)
            env.pop("FUSHI_TEST_ONSCREEN", None)
            if extra_env:
                env.update(extra_env)
            for sub in ("app-documents", "app-support", "temp", "webview2-profile"):
                (root / sub).mkdir(parents=True, exist_ok=True)

            self._sent = 0
            self._log_handle = self.stdout_log.open("wb")
            self._proc = subprocess.Popen(
                [str(self.exe), *self.exe_args],
                cwd=str(self.exe.parent),
                env=env,
                stdout=self._log_handle,
                stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )

        deadline = time.monotonic() + ready_timeout_s
        while time.monotonic() < deadline:
            text = self._read_out(0)
            if "home=" in text:
                return {"pid": self._proc.pid, "ready": text.strip(), "seeded": seeded}
            if self._proc.poll() is not None:
                raise GalDriverError(
                    f"驱动启动后退出 code={self._proc.returncode}\n"
                    f"out.txt:\n{text[-2000:]}\nstdout:\n{self._stdout_tail()}"
                )
            time.sleep(0.25)
        raise GalDriverError(
            f"{ready_timeout_s:.0f}s 内没等到 home= 就绪行（进程仍在运行 pid={self._proc.pid}）；"
            f"stdout:\n{self._stdout_tail()}"
        )

    def _seed(self, support: Optional[str], documents: Optional[str]) -> list[str]:
        """把真实数据目录复制进测试根（只在目标为空时复制，避免覆盖已有测试数据）。"""
        done: list[str] = []
        for src, sub in ((support, "app-support"), (documents, "app-documents")):
            if not src:
                continue
            src_path = Path(os.path.expandvars(src))
            if not src_path.is_dir():
                raise GalDriverError(f"seed 源目录不存在: {src_path}")
            dst = self.test_root / sub
            if dst.exists() and any(dst.iterdir()):
                done.append(f"{sub}: 已有数据，跳过（要重来用 reset_test_root）")
                continue
            shutil.copytree(src_path, dst, dirs_exist_ok=True)
            done.append(f"{sub} <- {src_path}")
        return done

    def stop(self, timeout_s: float = 20.0) -> dict[str, object]:
        # 不拿 _lock：正在执行的长指令卡住时也要能停。
        if not self.running():
            return {"stopped": False, "reason": "未运行"}
        proc = self._proc
        offset = self._out_size()
        if not (self.driver_dir / "cmd.txt").exists():
            try:
                self._write_cmd("quit")
            except OSError:
                pass
        # 独立运行的测试宿主（没有 flutter drive 收尾）跑完测试后进程不会自己退出：
        # 驱动写出收尾的 `exit` 行就说明捕获已停、假 AnkiConnect 已关，可以结束进程。
        deadline = time.monotonic() + timeout_s
        how = "timeout"
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                how = "quit"
                break
            if "] exit" in self._read_out(offset):
                how = "quit"
                break
            time.sleep(0.2)
        if proc.poll() is None:
            # 连带结束驱动拉起的子进程（helper 注入器、WebView2 等）。
            subprocess.run(
                ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                capture_output=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
            if how == "timeout":
                how = "killed"
        if self._log_handle is not None:
            self._log_handle.close()
            self._log_handle = None
        return {"stopped": True, "how": how, "exit_code": proc.returncode}

    # ── 指令 ────────────────────────────────────────────────────────────────

    def _write_cmd(self, command: str) -> None:
        tmp = self.driver_dir / "cmd.tmp"
        tmp.write_text(command + "\n", encoding="utf-8")
        os.replace(tmp, self.driver_dir / "cmd.txt")

    def command(self, command: str, timeout_s: float = 300.0) -> dict[str, object]:
        """发一条指令，等驱动执行完（done.txt 变化），返回这期间 out.txt 新增内容。"""
        command = command.strip()
        if not command or "\n" in command or "\r" in command:
            raise GalDriverError("一次只发一条单行指令")
        with self._lock:
            if not self.running():
                raise GalDriverError(
                    "驱动没在运行；先 galdriver_start" + self._exit_hint()
                )
            deadline = time.monotonic() + timeout_s
            cmd_file = self.driver_dir / "cmd.txt"
            while cmd_file.exists():
                if time.monotonic() > deadline or not self.running():
                    raise GalDriverError("上一条指令还没被驱动取走" + self._exit_hint())
                time.sleep(0.1)
            before_size = self._out_size()
            before_shots = self._shots()
            self._write_cmd(command)
            # 驱动的序号从启动起按条累加；本条完成 ⇔ done.txt ≥ 已发条数。不能用「done.txt
            # 变了」判定：上一条超时的慢指令迟到完成时也会改它。
            self._sent += 1
            target = self._sent
            while True:
                seq = self._done_seq()
                if seq is not None and seq.isdigit() and int(seq) >= target:
                    break
                if not self.running():
                    raise GalDriverError(
                        "驱动在执行指令时退出" + self._exit_hint()
                        + f"\nout:\n{self._read_out(before_size)[-3000:]}"
                    )
                if time.monotonic() > deadline:
                    raise GalDriverError(
                        f"{timeout_s:.0f}s 内指令未完成（驱动仍在跑，可再用 galdriver_status 看）"
                        f"\nout:\n{self._read_out(before_size)[-3000:]}"
                    )
                time.sleep(0.1)
            return {
                "seq": seq,
                "output": self._read_out(before_size),
                "new_shots": sorted(self._shots() - before_shots),
            }

    def _exit_hint(self) -> str:
        if self._proc is not None and self._proc.poll() is not None:
            return f"（进程已退出 code={self._proc.returncode}）\nstdout:\n{self._stdout_tail()}"
        return ""
