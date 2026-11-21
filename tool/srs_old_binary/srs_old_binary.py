#!/usr/bin/env python3
"""冻结的真实旧版本二进制实测装置（SRS 换代协议 4：G7 / G8 / G11 的合并条件）。

用**已发布的 Windows 发行包**（versions.json 钉死 sha256，不是源码里的旧模块）逐个版本跑一个动作，
看旧版本是拒绝还是接受、目标文件 / 位置 / 旧版本本机库有没有被写。说明：docs/agent/srs-old-binary-harness.md。

子命令：
  fetch  [--versions a,b]                         下载安装包、校验 sha256、innounp 解包 {app}
  run    --action A --target PATH [--versions ...] 对每个版本跑一遍，写结构化报告
  seed   --version ID --location DIR --out STATE   让某个旧版本以文件夹位置同步一次，留下它的数据根（sync-location 的 --state）
  list                                            列出 versions.json

隔离：每次启动都设 FUSHI_TEST_ROOT / FUSHI_TEST_HIDDEN / APPDATA / LOCALAPPDATA / TEMP / USERPROFILE /
WebView2 profile / FUSHI_CTL_DIR 到本次运行目录；只按 PID 或「可执行文件在本缓存目录里」结束进程，绝不按名字杀。
只用标准库；Windows only（旧版本是 Windows 发行包）。
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "versions.json"
REPO = "hajisensai/Fushi"
ACTIONS = ("open-db", "sync-location", "import-export", "restore-backup")
# 旧版本给出的「拒绝 / 需要升级」类提示在日志与控制通道回应里的关键词。
PROMPT_RE = re.compile(
    r"needs a newer app|newer|upgrade|minReader|unsupported|not a |schema|readonly|"
    r"backendUnsupported|升级|更新版本|比本版本新|不支持|不是有效",
    re.IGNORECASE,
)
SRS_DB = "srs.db"
CTL_DECKS = "/api/admin/srs/decks"
CTL_NAVIGATION = "/api/admin/navigation"
NAV_SRS = {"page": "srs"}
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# 会过期的 actions artifact / 会轮换的 debug-rolling 包都存档在这个 prerelease 里（versions.json 的 source.origin 记原来源）。
ARCHIVE_TAG = "srs-old-binaries-2026-11"
LOG_FILES = ("app-documents/error_log.txt", "app-documents/study_diag_log.txt")


# ── 通用 ────────────────────────────────────────────────────────────────


def cache_root() -> Path:
    env = os.environ.get("FUSHI_OLD_BINARY_CACHE", "").strip()
    return Path(env) if env else HERE / ".cache"


def _check_version(v: dict[str, Any]) -> dict[str, Any]:
    """versions.json 的值会进文件路径与 gh 的命令行：只认安全的名字、整数 run id、64 位十六进制 sha256。"""
    src = v["source"]
    names = [v["id"], src["asset"]] + [src[k] for k in ("tag", "artifact") if k in src]
    bad = [n for n in names if not isinstance(n, str) or not SAFE_NAME.fullmatch(n)]
    if bad or not re.fullmatch(r"[0-9a-f]{64}", v["installer_sha256"]):
        raise SystemExit(f"versions.json 里 {v.get('id')} 有不安全的值：{bad or v['installer_sha256']}")
    if src["kind"] == "actions-artifact" and not isinstance(src.get("run_id"), int):
        raise SystemExit(f"versions.json 里 {v['id']} 的 run_id 必须是整数")
    if src["kind"] not in ("release", "actions-artifact"):
        raise SystemExit(f"versions.json 里 {v['id']} 的来源未知：{src['kind']}")
    return v


def load_manifest() -> list[dict[str, Any]]:
    return [_check_version(v) for v in json.loads(MANIFEST.read_text(encoding="utf-8"))["versions"]]


def select_versions(spec: Optional[str]) -> list[dict[str, Any]]:
    versions = load_manifest()
    if not spec:
        return [v for v in versions if v.get("default")]
    if spec == "all":
        return versions
    wanted = [s.strip() for s in spec.split(",") if s.strip()]
    by_id = {v["id"]: v for v in versions}
    missing = [w for w in wanted if w not in by_id]
    if missing:
        raise SystemExit(f"versions.json 里没有：{', '.join(missing)}")
    return [by_id[w] for w in wanted]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot(root: Path) -> dict[str, str]:
    """root 下每个文件的相对路径 → sha256（root 是文件时键为它的文件名）。不存在 → 空。"""
    if root.is_file():
        return {root.name: sha256_file(root)}
    if not root.is_dir():
        return {}
    out: dict[str, str] = {}
    for p in sorted(root.rglob("*")):
        if p.is_file():
            out[p.relative_to(root).as_posix()] = sha256_file(p)
    return out


def diff_snapshots(before: dict[str, str], after: dict[str, str]) -> dict[str, Any]:
    added = sorted(k for k in after if k not in before)
    removed = sorted(k for k in before if k not in after)
    changed = sorted(k for k in before if k in after and before[k] != after[k])
    return {
        "unchanged": not (added or removed or changed),
        "added": added,
        "removed": removed,
        "changed": changed,
    }


def sqlite_logical_digest(db: Path) -> Optional[str]:
    """srs.db（连同 -wal）的逻辑内容摘要：拷到临时目录再读，按表名、rowid 顺序哈希全部行。"""
    if not db.is_file():
        return None
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / db.name
        shutil.copy2(db, copy)
        for side in ("-wal",):
            s = db.with_name(db.name + side)
            if s.is_file():
                shutil.copy2(s, Path(tmp) / s.name)
        h = hashlib.sha256()
        try:
            con = sqlite3.connect(str(copy))
            try:
                _hash_tables(con, h)
            finally:
                con.close()
        except sqlite3.DatabaseError as e:
            return f"unreadable:{e}"
        return h.hexdigest()


_UNKNOWN_FN = re.compile(r"(?:unknown|no such) function: (\w+)")


def _with_stub_functions(con: sqlite3.Connection, run: Callable[[], Any]) -> Any:
    """内核注册的 SQL 函数（虚拟生成列、触发器里用的 srs_* 等）在 Python 侧没有：遇到就补一个返回 NULL 的桩再重试。
    虚拟生成列本来就是派生值，比对时排除在外（见 [_hash_tables]）。"""
    for _ in range(64):
        try:
            return run()
        except sqlite3.OperationalError as e:
            m = _UNKNOWN_FN.search(str(e))
            if not m:
                raise
            con.create_function(m.group(1), -1, lambda *a: None)
    return run()


def table_digests(db: Path) -> Optional[dict[str, str]]:
    """每张表：行数 + 行内容摘要（同 [sqlite_logical_digest] 的口径）。"""
    if not db.is_file():
        return None
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / db.name
        shutil.copy2(db, copy)
        s = db.with_name(db.name + "-wal")
        if s.is_file():
            shutil.copy2(s, Path(tmp) / s.name)
        out: dict[str, str] = {}
        try:
            con = sqlite3.connect(str(copy))
            try:
                class _Per:
                    def __init__(self) -> None:
                        self.cur: Optional[str] = None
                        self.h = hashlib.sha256()
                        self.n = 0
                    def update(self, b: bytes) -> None:
                        if b.startswith(b"|table "):
                            self.flush()
                            self.cur = b.decode().split(" ")[1]
                            self.h, self.n = hashlib.sha256(), 0
                        else:
                            self.h.update(b)
                            self.n += 1
                    def flush(self) -> None:
                        if self.cur is not None:
                            out[self.cur] = f"{self.n}:{self.h.hexdigest()[:16]}"
                per = _Per()
                _hash_tables(con, per)  # type: ignore[arg-type]
                per.flush()
            finally:
                con.close()
        except sqlite3.DatabaseError as e:
            return {"<error>": str(e)}
        return out


def _changed_keys(a: Optional[dict[str, Any]], b: Optional[dict[str, Any]]) -> set[str]:
    a, b = a or {}, b or {}
    return {k for k in set(a) | set(b) if a.get(k) != b.get(k)}


def local_changes(before: dict[str, Any], after: dict[str, Any],
                  noise: Optional[dict[str, set[str]]]) -> dict[str, Any]:
    """本机库这次动作带来的、对照启动（没有动作的同样一次启动）解释不了的变化。"""
    tables = _changed_keys(before.get("tables"), after.get("tables"))
    meta = _changed_keys(before.get("srs_meta"), after.get("srs_meta"))
    nt = (noise or {}).get("tables", set())
    nm = (noise or {}).get("srs_meta", set())
    return {
        "changed_tables": sorted(tables),
        "changed_srs_meta_keys": sorted(meta),
        "unexplained_tables": sorted(t for t in tables if t != "srs_meta" and t not in nt),
        "unexplained_srs_meta_keys": sorted(k for k in meta if k not in nm),
        "control_run": noise is not None,
    }


def _hash_tables(con: sqlite3.Connection, h: "hashlib._Hash") -> None:
    tables = _with_stub_functions(con, lambda: [
        r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    ])
    for t in tables:
        cols = _with_stub_functions(con, lambda t=t: [
            r[1] for r in con.execute(f'PRAGMA table_xinfo("{t}")') if r[6] in (0, 3)
        ])
        h.update(f"|table {t} {cols}|".encode())
        if not cols:
            continue
        sel = ", ".join(f'"{c}"' for c in cols)
        def rows(t: str = t, sel: str = sel) -> list[Any]:
            try:
                return con.execute(f'SELECT {sel} FROM "{t}" ORDER BY rowid').fetchall()
            except sqlite3.OperationalError as e:
                if "rowid" not in str(e):
                    raise
                return sorted(con.execute(f'SELECT {sel} FROM "{t}"').fetchall(), key=repr)
        for row in _with_stub_functions(con, rows):
            h.update(repr(row).encode("utf-8", "backslashreplace"))


def srs_meta(db: Path) -> Optional[dict[str, str]]:
    if not db.is_file():
        return None
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / db.name
        shutil.copy2(db, copy)
        try:
            con = sqlite3.connect(str(copy))
            try:
                return dict(con.execute("SELECT key, value FROM srs_meta").fetchall())
            finally:
                con.close()
        except sqlite3.DatabaseError as e:
            return {"error": str(e)}


def byte_diff(a: Path, b: Path, limit: int = 64) -> dict[str, Any]:
    """两个文件逐字节比：长度与前 limit 个不同的偏移。SQLite 头里只有 24-27（文件改动计数）与 92-95（version-valid-for）
    不同 = 旧版本提交过一个事务、页内容没变——仍然是「写了」。"""
    x, y = a.read_bytes(), b.read_bytes()
    offs = [i for i in range(min(len(x), len(y))) if x[i] != y[i]]
    return {"len_before": len(x), "len_after": len(y), "differing_bytes": len(offs),
            "first_offsets": offs[:limit]}


def now_tag() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def log(msg: str) -> None:
    print(f"[srs-old-binary] {msg}", flush=True)


# ── 获取与解包 ──────────────────────────────────────────────────────────


def version_dir(v: dict[str, Any]) -> Path:
    return cache_root() / "versions" / v["id"]


def app_exe(v: dict[str, Any]) -> Path:
    if v.get("exe"):
        return Path(v["exe"])
    return version_dir(v) / "app" / "fushi.exe"


def local_build(exe: str) -> dict[str, Any]:
    """seed --exe：本地构建（例如 G7/G8/G11 分支的 Release 产物）当作一个「版本」来驱动，用来造新代文件 / 位置 / 包。"""
    p = Path(exe).resolve()
    if not p.is_file():
        raise SystemExit(f"不存在：{p}")
    return {"id": "local-" + hashlib.sha256(str(p).encode()).hexdigest()[:8], "exe": str(p),
            "app_version": "local", "commit": "local", "srs_protocol": "?", "installer_sha256": "",
            "has_srs_db": True, "has_folder_location": True}


def fetch_one(v: dict[str, Any]) -> Path:
    vd = version_dir(v)
    dl = vd / "download"
    dl.mkdir(parents=True, exist_ok=True)
    src = v["source"]
    installer = dl / src["asset"]  # NOSONAR —— asset 已经 _check_version 校验成安全文件名
    want = v["installer_sha256"]
    stamp = vd / "app" / ".installer_sha256"
    if stamp.is_file() and stamp.read_text().strip() == want and app_exe(v).is_file():  # NOSONAR —— 缓存目录内的自写戳
        return app_exe(v)
    for attempt in range(5):
        if installer.is_file() and sha256_file(installer) == want:
            break
        if installer.exists():
            installer.unlink()
        log(f"{v['id']}: 下载 {src['asset']}（第 {attempt + 1} 次）")
        if src["kind"] == "release":
            cmd = ["gh", "release", "download", src["tag"], "--repo", REPO,
                   "-p", src["asset"], "-D", str(dl), "--clobber"]
        elif src["kind"] == "actions-artifact":
            cmd = ["gh", "run", "download", str(src["run_id"]), "--repo", REPO,
                   "-n", src["artifact"], "-D", str(dl)]
        else:
            raise SystemExit(f"未知来源：{src['kind']}")
        subprocess.run(cmd, check=False)  # NOSONAR —— 参数列表不经 shell，值已 _check_version 校验
    else:
        if not installer.is_file() or sha256_file(installer) != want:
            raise SystemExit(
                f"{v['id']}: 安装包 sha256 对不上或下载失败（期望 {want}）。"
                + (f" actions artifact 在 {src.get('expires_at')} 过期，过期后只剩已缓存的副本。"
                   if src["kind"] == "actions-artifact" else "")
            )
    innounp = shutil.which("innounp")
    if not innounp:
        raise SystemExit("缺 innounp（Inno Setup 6.7 安装包解包器）：scoop install innounp")
    app = vd / "app"
    if app.exists():
        shutil.rmtree(app)
    log(f"{v['id']}: innounp 解包")
    r = subprocess.run([innounp, "-x", "-y", f"-d{app}", "-c{app}", str(installer)],  # NOSONAR —— 同上
                       capture_output=True, text=True, errors="replace")
    if r.returncode != 0 or not app_exe(v).is_file():  # NOSONAR —— 路径来自校验过的 id
        raise SystemExit(f"{v['id']}: 解包失败\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    stamp.write_text(want)
    return app_exe(v)


# ── 进程与控制通道 ──────────────────────────────────────────────────────


def processes_under(dir_: Path) -> list[int]:
    """可执行文件位于 dir_ 之下的进程 PID（只认路径，不认名字）。"""
    ps = (
        "Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and "
        f"$_.ExecutablePath.StartsWith('{str(dir_.resolve())}', "
        "[System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.ProcessId }"
    )
    r = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       capture_output=True, text=True)
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def kill_pids(pids: list[int]) -> None:
    for pid in pids:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                       capture_output=True, text=True)


class App:
    """一次旧版本进程：隔离环境启动、控制通道、按 PID 收尾。"""

    def __init__(self, v: dict[str, Any], run_dir: Path, onscreen: bool = False):
        self.v = v
        self.run_dir = run_dir
        self.data = run_dir / "data"
        self.ctl_dir = run_dir / "ctl"
        self.onscreen = onscreen
        self.proc: Optional[subprocess.Popen[bytes]] = None
        self.endpoint: Optional[dict[str, Any]] = None
        self.launches = 0

    def env(self) -> dict[str, str]:
        env = dict(os.environ)
        def sub(name: str) -> str:
            p = self.run_dir / "env" / name
            p.mkdir(parents=True, exist_ok=True)
            return str(p)
        self.data.mkdir(parents=True, exist_ok=True)
        self.ctl_dir.mkdir(parents=True, exist_ok=True)
        env.update(
            FUSHI_TEST_HIDDEN="1",
            FUSHI_TEST_ROOT=str(self.data),
            FUSHI_TEST_RUN_ID=f"srs-old-binary-{self.v['id']}",
            FUSHI_WEBVIEW2_USER_DATA_FOLDER=sub("webview2"),
            FUSHI_CTL_DIR=str(self.ctl_dir),
            APPDATA=sub("appdata"),
            LOCALAPPDATA=sub("localappdata"),
            TEMP=sub("temp"),
            TMP=sub("temp"),
            USERPROFILE=sub("userprofile"),
        )
        if self.onscreen:
            env["FUSHI_TEST_ONSCREEN"] = "1"
        else:
            env.pop("FUSHI_TEST_ONSCREEN", None)
        for k in ("FUSHI_DEV_SIDE_BY_SIDE", "FUSHI_CTL"):
            env.pop(k, None)
        return env

    def start(self, ready_timeout: float = 180) -> dict[str, Any]:
        exe = app_exe(self.v)
        busy = processes_under(exe.parent)
        if busy:
            raise RuntimeError(
                f"{self.v['id']} 的缓存二进制已有进程在跑（PID {busy}），不并发同一版本、不替它收尾"
            )
        ep = self.ctl_dir / "endpoint.json"
        if ep.exists():
            ep.unlink()
        self.launches += 1
        self.run_dir.mkdir(parents=True, exist_ok=True)
        out = open(self.run_dir / f"stdout-{self.launches}.log", "wb")
        self.proc = subprocess.Popen([str(exe)], env=self.env(), cwd=str(exe.parent),
                                     stdout=out, stderr=subprocess.STDOUT)
        return self.wait_ready(ready_timeout)

    def wait_ready(self, timeout: float, not_pid: Optional[int] = None) -> dict[str, Any]:
        ep = self.ctl_dir / "endpoint.json"
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc is not None and not_pid is None and self.proc.poll() is not None:
                raise RuntimeError(f"进程提前退出，退出码 {self.proc.returncode}")
            if ep.is_file():
                try:
                    e = json.loads(ep.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError):
                    e = None
                if e and e.get("pid") != not_pid:
                    self.endpoint = e
                    st = self.call("GET", "/api/admin/status")
                    if st["status"] == 200 and (st["json"] or {}).get("initialised"):
                        return st["json"]
            time.sleep(1)
        raise RuntimeError("控制通道没在时限内就绪")

    def call(self, method: str, path: str, body: Optional[dict[str, Any]] = None,
             query: Optional[dict[str, str]] = None, timeout: float = 120) -> dict[str, Any]:
        assert self.endpoint is not None
        url = f"http://127.0.0.1:{self.endpoint['port']}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        req = urllib.request.Request(
            url, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.endpoint['token']}",
                     "Content-Type": "application/json"},
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=timeout) as r:
                status, raw = r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read().decode("utf-8", "replace")
        except OSError as e:  # URLError 是 OSError 的子类
            return {"method": method, "path": path, "status": None, "error": str(e), "json": None}
        try:
            js = json.loads(raw)
        except json.JSONDecodeError:
            js = None
        return {"method": method, "path": path, "status": status, "json": js,
                "body": raw if js is None else None}

    def quit(self, timeout: float = 90) -> dict[str, Any]:
        """控制通道请它退出；超时按 PID 结束本缓存二进制下的进程。返回收尾方式。"""
        how = "ctl-quit"
        if self.endpoint is not None:
            self.call("POST", "/api/admin/app/quit", {}, timeout=15)
        exe_dir = app_exe(self.v).parent
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not processes_under(exe_dir):
                break
            time.sleep(1)
        else:
            how = "killed-by-pid"
            kill_pids(processes_under(exe_dir))
            time.sleep(2)
        self.endpoint = None
        return {"how": how, "exit_code": self.proc.returncode if self.proc else None}


# ── 运行目录准备 ────────────────────────────────────────────────────────


def support_dir(app: App) -> Path:
    return app.data / "app-support"


def local_db_state(app: App) -> dict[str, Any]:
    sd = support_dir(app)
    files = {k: v for k, v in snapshot(sd).items()
             if "/" not in k and k.startswith("srs")}
    return {
        "files": files,
        "srs_meta": srs_meta(sd / "srs.db"),
        "logical": sqlite_logical_digest(sd / "srs.db"),
        "tables": table_digests(sd / "srs.db"),
    }


def read_logs(app: App) -> dict[str, int]:
    out: dict[str, int] = {}
    for rel in LOG_FILES:
        p = app.data / rel
        out[rel] = p.stat().st_size if p.is_file() else 0
    for p in sorted(app.run_dir.glob("stdout-*.log")):
        out[p.name] = p.stat().st_size
    return out


def new_log_text(app: App, sizes: dict[str, int]) -> dict[str, str]:
    out: dict[str, str] = {}
    paths = {rel: app.data / rel for rel in LOG_FILES}
    paths.update({p.name: p for p in app.run_dir.glob("stdout-*.log")})
    for name, p in paths.items():
        if not p.is_file():
            continue
        with p.open("rb") as f:
            f.seek(sizes.get(name, 0))
            text = f.read().decode("utf-8", "replace")
        if text.strip():
            out[name] = text
    return out


def prompt_lines(texts: list[str]) -> list[str]:
    lines: list[str] = []
    for t in texts:
        for line in t.splitlines():
            s = line.strip()
            if s and PROMPT_RE.search(s) and s not in lines:
                lines.append(s[:400])
    return lines[:40]


def set_prefs(app: App, prefs: dict[str, str], profile_uid: Optional[str] = None) -> None:
    """app 不在跑时直接写旧版本 fushi.db 的 preferences（值带类型前缀 s: / b:），可选改当前 profile 的 uid。"""
    db = support_dir(app) / "fushi.db"
    con = sqlite3.connect(str(db))
    try:
        ts = int(time.time() * 1000)
        for k, v in prefs.items():
            con.execute(
                "INSERT OR REPLACE INTO preferences(key, value, updated_at) VALUES (?, ?, ?)",
                (k, v, ts),
            )
        if profile_uid:
            row = con.execute(
                "SELECT value FROM preferences WHERE key='active_profile_id'"
            ).fetchone()
            pid = int(row[0]) if row and str(row[0]).isdigit() else 1
            con.execute("UPDATE profiles SET uid=? WHERE id=?", (profile_uid, pid))
        con.commit()
    finally:
        con.close()


def folder_location_prefs(loc: Path) -> dict[str, str]:
    """旧版本 `preferences` 里「这个文件夹是同步位置」+「首次同步已确认」两项（值带类型前缀）。"""
    return {
        "srs_sync2_folder_locations": "s:" + json.dumps(
            [{"id": "harness", "path": str(loc), "sync": True, "media": True, "archive": False}]),
        "srs_sync2_merge_confirmed": "b:true",
    }


def profile_uids_in_location(loc: Path) -> list[str]:
    ns = loc / "fushi-srs"
    return sorted(p.name for p in ns.iterdir() if p.is_dir()) if ns.is_dir() else []


def copy_into(src: Path, dst: Path) -> None:
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def wait_quiet(paths: list[Path], quiet: float, max_wait: float) -> float:
    """等 paths（文件 / 目录树）在 quiet 秒内不再变化，最多 max_wait 秒。返回实际等待秒数。"""
    def sig() -> tuple[Any, ...]:
        out = []
        for p in paths:
            if p.is_dir():
                out.extend((q.as_posix(), q.stat().st_size, q.stat().st_mtime_ns)
                           for q in p.rglob("*") if q.is_file())
            elif p.is_file():
                out.append((p.as_posix(), p.stat().st_size, p.stat().st_mtime_ns))
        return tuple(sorted(out))
    start = time.time()
    last, last_change = sig(), time.time()
    while time.time() - start < max_wait:
        time.sleep(1)
        cur = sig()
        if cur != last:
            last, last_change = cur, time.time()
        elif time.time() - last_change >= quiet:
            break
    return round(time.time() - start, 1)


# ── 动作 ────────────────────────────────────────────────────────────────


def control_launch(app: App, action: str, args: argparse.Namespace) -> dict[str, set[str]]:
    """对照：同样启动一次、同样进复习页、同样等，但不给目标。返回这次「什么都没做」也会变的表 / srs_meta 键
    （旧版本每次启动都会写自己的库：设备信息、摘要时刻、启动记录……）。"""
    s0 = local_db_state(app)
    app.start()
    if action == "sync-location":
        app.call("POST", CTL_NAVIGATION, NAV_SRS)
    wait_quiet([support_dir(app)], quiet=10, max_wait=min(args.settle, 60))
    app.quit()
    s1 = local_db_state(app)
    return {"tables": _changed_keys(s0.get("tables"), s1.get("tables")),
            "srs_meta": _changed_keys(s0.get("srs_meta"), s1.get("srs_meta"))}


def prepare_root(app: App, state: Optional[Path]) -> str:
    """数据根：给了 --state 就拷它（<state>/<版本 id>/data 优先，其次 <state>/data），否则热启动一次建空根。"""
    if state is not None:
        for cand in (state / app.v["id"] / "data", state / "data"):
            if cand.is_dir():
                copy_into(cand, app.data)
                return f"state:{cand}"
        raise RuntimeError(f"--state 下没有 {app.v['id']}/data 或 data")
    app.start()
    app.quit()
    return "fresh"


def place_db(app: App, target: Path) -> None:
    """open-db：目标是文件 → 放成 app-support/srs.db（连同同名 -wal / -shm）；是目录 → 目录里的文件原样拷进 app-support。"""
    sd = support_dir(app)
    for p in sd.glob("srs.db*"):
        p.unlink()
    if target.is_file():
        shutil.copy2(target, sd / "srs.db")
        for side in ("-wal", "-shm"):
            s = target.with_name(target.name + side)
            if s.is_file():
                shutil.copy2(s, sd / ("srs.db" + side))
        return
    for p in target.iterdir():
        if p.is_file():
            shutil.copy2(p, sd / p.name)


def target_files(app: App, target: Path) -> list[Path]:
    sd = support_dir(app)
    if target.is_file():
        return [sd / n for n in ("srs.db", "srs.db-wal", "srs.db-shm")]
    return [sd / p.name for p in target.iterdir() if p.is_file()]


def snap_files(files: list[Path]) -> dict[str, str]:
    return {f.name: sha256_file(f) for f in files if f.is_file()}


def run_version(v: dict[str, Any], action: str, target: Path, args: argparse.Namespace,
                runs_root: Path) -> dict[str, Any]:
    run_dir = runs_root / v["id"]
    run_dir.mkdir(parents=True, exist_ok=True)
    app = App(v, run_dir, onscreen=args.manual)
    rep: dict[str, Any] = {
        "version": v["id"], "app_version": v["app_version"], "commit": v["commit"],
        "srs_protocol": v["srs_protocol"], "installer_sha256": v["installer_sha256"],
        "action": action, "run_dir": str(run_dir), "ctl": [], "notes": [],
        "manual": bool(args.manual),
    }
    try:
        rep["data_root"] = prepare_root(app, args.state)
        noise: Optional[dict[str, set[str]]] = None
        adopt: Optional[str] = None
        if action == "sync-location":
            uids = profile_uids_in_location(target)
            adopt = args.profile_uid or (uids[0] if len(uids) == 1 and not args.state else None)
            rep["location_profiles"] = uids
            rep["adopted_profile_uid"] = adopt
            if not args.no_control:
                # 对照启动先对一个空的占位位置同步一轮：首次开同步带来的本机变化（旧库并成操作、设备身份……）
                # 都落在对照里，正式那一轮只剩「读到这个位置」带来的变化。
                # 目录必须先存在：调度器跳过不存在的文件夹位置（U 盘没插）。
                (run_dir / "control-location").mkdir(parents=True, exist_ok=True)
                set_prefs(app, folder_location_prefs(run_dir / "control-location"), profile_uid=adopt)
        if action != "open-db" and not args.no_control:
            noise = control_launch(app, action, args)
            rep["control_noise"] = {k: sorted(v) for k, v in noise.items()}
            if action == "sync-location":
                # 对照那一轮往占位位置写了东西，说明这个版本的文件夹位置同步确实在跑（「没写目标」不是因为根本没跑）。
                rep["control_location_files"] = len(snapshot(run_dir / "control-location"))
        # ── 放目标 ──
        if action == "open-db":
            place_db(app, target)
            watch = target_files(app, target)
            before_target = snap_files(watch)
            # open-db 的「本机库」就是目标本身；另记 fushi.db 只作参考。
        elif action == "sync-location":
            loc = run_dir / "location"
            if loc.exists():
                shutil.rmtree(loc)
            copy_into(target, loc)
            set_prefs(app, folder_location_prefs(loc), profile_uid=adopt)
            watch = [loc]
            before_target = snapshot(loc)
        else:  # import-export / restore-backup：包放进 input/，只读它
            inp = run_dir / "input"
            inp.mkdir(parents=True, exist_ok=True)
            pkg = inp / target.name
            shutil.copy2(target, pkg)
            watch = [pkg]
            before_target = snapshot(pkg)
        before_local = local_db_state(app)
        sizes = read_logs(app)

        # ── 跑动作 ──
        status = app.start()
        rep["status"] = status
        if not v.get("has_srs_db") and action in ("open-db",):
            rep["notes"].append("此版本没有 srs.db（复习数据在 fushi.db），open-db 对它不适用：只记目标是否被碰")
        if not v.get("has_folder_location") and action == "sync-location":
            rep["notes"].append("此版本没有复习同步的文件夹位置，sync-location 不适用：只记位置是否被碰")
        restarted = False
        if action == "open-db":
            rep["ctl"].append(app.call("GET", CTL_DECKS))
            rep["ctl"].append(app.call("POST", CTL_NAVIGATION, NAV_SRS))
            time.sleep(3)
            rep["ctl"].append(app.call("GET", CTL_DECKS))
            rep["waited_s"] = wait_quiet(watch, quiet=5, max_wait=args.settle)
        elif action == "sync-location":
            rep["ctl"].append(app.call("POST", CTL_NAVIGATION, NAV_SRS))
            rep["waited_s"] = wait_quiet(watch + [app.data / "app-documents"], quiet=10,
                                         max_wait=args.settle)
            rep["ctl"].append(app.call("GET", CTL_DECKS))
        elif action == "restore-backup":
            pkg = watch[0]
            rep["ctl"].append(app.call("GET", "/api/admin/backups/info", query={"path": str(pkg)}))
            r = app.call("POST", "/api/admin/backups/restore",
                         {"path": str(pkg), "mode": args.restore_mode, "confirm": True})
            rep["ctl"].append(r)
            if r["status"] == 200:
                # 接受了：app 导入后会自己重启（新进程，同一个可执行文件、同一套环境）。
                old_pid = (app.endpoint or {}).get("pid")
                try:
                    app.wait_ready(args.settle, not_pid=old_pid)
                    restarted = True
                    rep["ctl"].append(app.call("GET", CTL_DECKS))
                except RuntimeError as e:
                    rep["notes"].append(f"恢复后没等到重启就绪：{e}")
            else:
                rep["waited_s"] = wait_quiet(watch, quiet=3, max_wait=10)
        elif action == "import-export":
            if not args.manual:
                rep["notes"].append(
                    "已发布版本的控制通道没有 .fushisrs 导入入口，这个动作只能 --manual：装置把窗口放到屏上，"
                    "由人在复习 › 历史页里导入 input/ 下的包，回车后装置收尾比对")
            else:
                rep["notes"].append(f"手动：在复习 › 历史页导入 {watch[0]}，完成后回到终端按回车")
                input(f"[{v['id']}] 导入 {watch[0]} 后按回车继续…")
        if args.manual and action != "import-export":
            input(f"[{v['id']}] 手动检查完按回车收尾…")
        rep["quit"] = app.quit()
        rep["restarted"] = restarted

        # ── 比对 ──
        if action == "open-db":
            after_target = snap_files(watch)
        else:
            after_target = snapshot(watch[0])
        rep["target"] = {"before": before_target, "after": after_target,
                         **diff_snapshots(before_target, after_target)}
        if action == "open-db" and target.is_file() and "srs.db" in rep["target"]["changed"]:
            rep["target"]["srs_db_byte_diff"] = byte_diff(target, support_dir(app) / "srs.db")
        after_local = local_db_state(app)
        rep["local_db"] = {
            "before": before_local, "after": after_local,
            "files_unchanged": before_local["files"] == after_local["files"],
            "logical_unchanged": before_local["logical"] == after_local["logical"],
            **local_changes(before_local, after_local, noise),
        }
        texts = new_log_text(app, sizes)
        ctl_texts = [json.dumps(c.get("json") or c.get("body") or c.get("error"), ensure_ascii=False)
                     for c in rep["ctl"]]
        rep["prompt_lines"] = prompt_lines(ctl_texts + list(texts.values()))
        (run_dir / "new-logs.json").write_text(json.dumps(texts, ensure_ascii=False, indent=1),
                                               encoding="utf-8")
        rep["verdict"] = judge(action, v, rep)
    except Exception as e:  # noqa: BLE001 —— 一个版本出错要记进报告，不挡其余版本
        rep["verdict"] = "harness-error"
        rep["error"] = f"{type(e).__name__}: {e}"
        try:
            app.quit(timeout=30)
        except Exception:  # noqa: BLE001
            pass
    return rep


SIDECAR_RE = re.compile(r"-(wal|shm|journal)$")


def sidecars_only(diff: dict[str, Any]) -> bool:
    """原有文件一个字节没变，只多出 SQLite 的 -wal / -shm / -journal 旁文件。"""
    return (not diff.get("changed") and not diff.get("removed") and bool(diff.get("added"))
            and all(SIDECAR_RE.search(a) for a in diff.get("added", [])))


def judge(action: str, v: dict[str, Any], rep: dict[str, Any]) -> str:
    """rejected = 明确拒绝（控制通道报错 / 有升级类提示）且目标与本机库都一个字节没变；
    rejected-sidecars-only = 拒绝了、原有文件没变，只多了 SQLite 旁文件；accepted = 旧版本照常处理了目标；
    rejected-but-wrote 是要追的红。"""
    touched = not rep["target"]["unchanged"]
    # 旧版本自己的库每次启动都会被它自己打开（SQLite 头的改动计数等会变），所以本机库按逻辑内容判；
    # 文件字节变没变照样记在报告里（local_db.files_unchanged）。
    ld = rep["local_db"]
    if "unexplained_tables" in ld:
        local_changed = bool(ld["unexplained_tables"] or ld["unexplained_srs_meta_keys"])
    else:
        local_changed = not ld["logical_unchanged"]
    prompts = bool(rep["prompt_lines"])
    if action == "open-db":
        if not v.get("has_srs_db"):
            return "n/a-touched" if touched else "n/a-untouched"
        refused = any(c["path"] == CTL_DECKS and c.get("status") != 200 for c in rep["ctl"])
        if refused:
            if not touched:
                return "rejected"
            return "rejected-sidecars-only" if sidecars_only(rep["target"]) else "rejected-but-wrote"
        return "accepted"
    if action == "sync-location":
        if not v.get("has_folder_location"):
            return "n/a-touched" if touched else "n/a-untouched"
        if prompts and not touched and not local_changed:
            return "rejected"
        if prompts:
            return "rejected-but-wrote"
        # 没写也没在日志 / 控制通道里留下提示：已发布版本的文件夹位置「需要升级」只进界面与内存诊断，不落盘，
        # 字节不变能自动判，提示要 --manual 人眼看（docs/agent/srs-old-binary-harness.md）。
        if touched:
            return "accepted"
        return "untouched-but-local-changed" if local_changed else "untouched-prompt-unverified"
    if action == "restore-backup":
        restore = next((c for c in rep["ctl"] if c["path"].endswith("/restore")), None)
        if restore and restore.get("status") != 200:
            return "rejected" if not (touched or local_changed) else "rejected-but-wrote"
        return "accepted"
    if action == "import-export":
        if not rep.get("manual"):
            return "not-automatable"
        if prompts and not touched and not local_changed:
            return "rejected"
        return "accepted" if local_changed else "no-effect"
    return "unknown"


# ── 子命令 ──────────────────────────────────────────────────────────────


def cmd_list(_: argparse.Namespace) -> int:
    for v in load_manifest():
        mark = "*" if v.get("default") else " "
        print(f"{mark} {v['id']:<24} {v['app_version']:<20} protocol={v['srs_protocol']:<10} {v['role']}")
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    for v in select_versions(args.versions):
        exe = fetch_one(v)
        log(f"{v['id']}: {exe}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    target = Path(args.target).resolve()
    if not target.exists():
        raise SystemExit(f"目标不存在：{target}")
    if args.action == "sync-location" and not target.is_dir():
        raise SystemExit("sync-location 的目标必须是位置目录（含 fushi-srs/）")
    if args.action in ("import-export", "restore-backup") and not target.is_file():
        raise SystemExit(f"{args.action} 的目标必须是一个文件")
    args.state = Path(args.state).resolve() if args.state else None
    target_hash_before = snapshot(target)
    runs_root = cache_root() / "runs" / f"{now_tag()}-{args.action}"
    reports = []
    # --exe：本地构建（换代分支的 Release 产物）当一个「版本」跑同一套动作，例如 R0 的「旧备份 → 新版本还原」。
    versions = [local_build(args.exe)] if args.exe else select_versions(args.versions)
    for v in versions:
        if not args.exe:
            fetch_one(v)
        log(f"{v['id']}: {args.action} {target}")
        rep = run_version(v, args.action, target, args, runs_root)
        log(f"{v['id']}: {rep['verdict']}" + (f"（{rep.get('error')}）" if rep.get("error") else ""))
        reports.append(rep)
    original_unchanged = snapshot(target) == target_hash_before
    out = {
        "generated_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "action": args.action,
        "target": str(target),
        "target_sha256": target_hash_before,
        "original_target_unchanged": original_unchanged,
        "runs_root": str(runs_root),
        "results": reports,
    }
    report_path = Path(args.report) if args.report else runs_root / "report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(out, ensure_ascii=False, indent=1),  # NOSONAR —— 操作者给的报告路径
                           encoding="utf-8")
    print(summary_table(out))
    log(f"报告：{report_path}")
    bad = [r for r in reports if r["verdict"] in ("harness-error",)]
    if args.expect:
        allowed = {x.strip() for x in args.expect.split(",") if x.strip()}
        bad += [r for r in reports if r["verdict"] not in allowed
                and not r["verdict"].startswith("n/a")]
    return 1 if bad else 0


def summary_table(out: dict[str, Any]) -> str:
    rows = ["| 版本 | 协议 | 动作 | 结论 | 目标逐字节不变 | 本机库不变（文件 / 逻辑） | 提示 |",
            "|---|---|---|---|---|---|---|"]
    for r in out["results"]:
        t = r.get("target", {})
        l = r.get("local_db", {})
        prompt = (r.get("prompt_lines") or [r.get("error", "")])[:1]
        rows.append(
            f"| {r['version']} | {r['srs_protocol']} | {r['action']} | {r['verdict']} | "
            f"{t.get('unchanged', '-')} | {l.get('files_unchanged', '-')} / {l.get('logical_unchanged', '-')} | "
            f"{(prompt[0] if prompt else '')[:120].replace('|', '/')} |"
        )
    return "\n".join(rows)


def cmd_seed(args: argparse.Namespace) -> int:
    """用某个版本（或 --exe 本地构建）在隔离数据根里造输入：可选把一个文件夹位置同步一轮（位置原地被写，它就是
    要造的位置）、可选导出一个备份包；最后把数据根留在 <out>/<版本 id>/data（sync-location 的 --state、open-db 的 srs.db 来源）。"""
    if args.exe:
        v = local_build(args.exe)
    else:
        (v,) = select_versions(args.version)
        fetch_one(v)
    out = Path(args.out).resolve() / v["id"]
    if out.exists():
        raise SystemExit(f"{out} 已存在")
    run_dir = cache_root() / "runs" / f"{now_tag()}-seed-{v['id']}"
    app = App(v, run_dir)
    app.start()
    app.quit()
    result: dict[str, Any] = {"version": v["id"], "exe": str(app_exe(v)), "state": str(out)}
    loc: Optional[Path] = None
    if args.location:
        loc = Path(args.location).resolve()
        loc.mkdir(parents=True, exist_ok=True)
        uid = args.profile_uid or str(uuid.uuid4())
        set_prefs(app, folder_location_prefs(loc), profile_uid=uid)
        result.update(profile_uid=uid, location=str(loc))
    elif args.profile_uid:
        set_prefs(app, {}, profile_uid=args.profile_uid)
        result["profile_uid"] = args.profile_uid
    app.start()
    if loc is not None:
        result["navigate"] = app.call("POST", CTL_NAVIGATION, NAV_SRS)["status"]
        result["waited_s"] = wait_quiet([loc], quiet=10, max_wait=args.settle)
        result["location_files"] = len(snapshot(loc))
    if args.backup_out:
        bo = Path(args.backup_out).resolve()
        bo.parent.mkdir(parents=True, exist_ok=True)
        r = app.call("POST", "/api/admin/backups", {"output": str(bo), "all": True}, timeout=600)
        result["backup"] = {"path": str(bo), "status": r["status"],
                            "response": r.get("json") or r.get("body") or r.get("error")}
    result["decks"] = app.call("GET", CTL_DECKS).get("json")
    app.quit()
    shutil.copytree(app.data, out / "data")
    meta = srs_meta(out / "data" / "app-support" / "srs.db") or {}
    result["srs_meta"] = {k: v for k, v in meta.items() if not k.startswith("sync2_")}
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    if os.name != "nt":
        raise SystemExit("只支持 Windows（旧版本是 Windows 发行包）")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("list").set_defaults(fn=cmd_list)
    f = sp.add_parser("fetch")
    f.add_argument("--versions", help="逗号分隔的 id；all = 全部；缺省 = default 口径")
    f.set_defaults(fn=cmd_fetch)
    r = sp.add_parser("run")
    r.add_argument("--action", required=True, choices=ACTIONS)
    r.add_argument("--target", required=True)
    r.add_argument("--versions")
    r.add_argument("--exe", help="本地构建的 fushi.exe 代替 --versions（新版本对旧输入的同一套动作）")
    r.add_argument("--state", help="旧版本已有的数据根（seed 产物：<state>/<版本 id>/data）")
    r.add_argument("--profile-uid", help="sync-location：把旧版本当前 profile 的 uid 改成它（缺省：位置里只有一个 uid 且没给 --state 时自动采用）")
    r.add_argument("--restore-mode", default="merge", choices=("merge", "replace"))
    r.add_argument("--settle", type=float, default=90, help="动作后最多等多少秒（静默即提前结束）")
    r.add_argument("--manual", action="store_true", help="窗口放到屏上，人工操作后回车收尾")
    r.add_argument("--no-control", action="store_true", help="不做对照启动（本机库变化就按逻辑内容整体判）")
    r.add_argument("--expect", help="期望结论，逗号分隔的完整取值（如 rejected,untouched-prompt-unverified）；有版本不在其中（n/a-* 除外）则退出码 1")
    r.add_argument("--report")
    r.set_defaults(fn=cmd_run)
    s = sp.add_parser("seed")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--version")
    g.add_argument("--exe", help="本地构建的 fushi.exe（造新代文件 / 位置 / 包用）")
    s.add_argument("--location", help="要同步出来的文件夹位置")
    s.add_argument("--backup-out", help="顺手导出一个备份包到这个路径")
    s.add_argument("--out", required=True)
    s.add_argument("--profile-uid")
    s.add_argument("--settle", type=float, default=90)
    s.set_defaults(fn=cmd_seed)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
