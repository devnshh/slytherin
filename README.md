<div align="center">

# slytherin

**Single-file Linux cover-tracks tool for authorized red-team operations.**

One Python file. No dependencies. Snapshot before you act, vanish after you're done.

</div>

---

> [!CAUTION]
> **Authorized use only.** slytherin is built for red-team engagements, penetration
> testing, and security research on systems you **own** or have **explicit written
> permission** to test. Covering tracks on a system without authorization is illegal
> in most jurisdictions. The authors accept no liability for misuse.

## What it does

slytherin is a single portable script that covers the tracks an engagement
leaves on a Linux box:

- **Session model** - snapshot log contents + filesystem timestamps *before*
  exploitation, revert everything *after*
- **Permissions-aware dry-run** - see which trace files exist and which you can
  actually write, before committing to anything
- **Multi-pass random-overwrite shred** - defeat file recovery, not just `rm`
- **Timestamp rewriting** with view/recurse semantics
- **Surgical login-record stripping** - remove *your* records from
  utmp/wtmp/btmp via `utmpdump`, leave everyone else's intact
- **journald trim** - `--rotate` + `--vacuum-time` on the systemd binary journal
- **shred hardening** - page-cache drop (`posix_fadvise`) + rename-before-unlink
  so filenames can't be recovered
- **Session package tracking** - diff the dpkg package list against the
  session-start baseline and purge what the session added

The core philosophy: **reverting beats destroying.** A log file restored to its
pre-session state (bytes + timestamps) raises far fewer flags than a log file
that was wiped, truncated, or has a 1102-style "log cleared" event attached to it.

---

## Installation

It's one file - fetch and run:

```bash
curl -sSL https://raw.githubusercontent.com/<you>/slytherin/main/slytherin.py -o slytherin
chmod +x slytherin
./slytherin --help
```

Or clone the repo:

```bash
git clone https://github.com/<you>/slytherin.git
cd slytherin
python3 slytherin.py --help
```

Requirements: **Python 3.6+** on **Linux**. Standard library only - nothing to pip install.

---

## The workflow: start → get → finish

The typical engagement loop is a session. `start` snapshots the state of known
trace files (logs, shell histories, login records) into a hidden 0700 directory
in `/tmp`. You do your work. `finish` reverts every snapshotted file to its
exact pre-session bytes and timestamps, strips every `slytherin` invocation from
shell history, then securely overwrites and removes the session directory.

```bash
# 1. Start the session immediately after landing a shell
$ slytherin start
[slytherin] [+] session started: snapshot of 12 files in /tmp/.slytherin-0
[slytherin] [!] actions taken by OTHER processes during this session will be reverted too

# 2. Mid-session, before touching any file the snapshot doesn't know about,
#    record its pre-state so finish can revert it
$ slytherin get /etc/shadow
[slytherin] [+] recorded pre-state of /etc/shadow for revert at finish

$ slytherin get /var/www/html/config.php
[slytherin] [+] recorded pre-state of /var/www/html/config.php for revert at finish

# 3. ... do the work ...

# 4. Done. Revert everything, scrub history, remove the session
$ slytherin finish
[slytherin] [+] restored 14 files to pre-session state, stripped 1 history line(s)
[slytherin] [!] the current shell will still append its buffered history on exit -
              run 'history -c && unset HISTFILE' before closing
```

Nothing left behind: the config you read, the timestamp you bumped, the commands
you typed - all reverted to how the box looked when you arrived.

### One command, before anything else

Always run `status` first. It is a **dry-run** - it lists every trace file it
knows about, its size, and whether the *current user* can write to it:

```bash
$ slytherin status
  ro       4,812 B  /var/log/auth.log
  rw         173 B  /root/.bash_history
  rw      35,921 B  /root/.zsh_history
  rw      12,004 B  /var/log/wtmp
  ro           -    /var/log/audit/audit.log

  5 trace file(s) found, 3 writable as current user
  dry-run only - nothing was modified
```

If a file shows `ro`, a later `finish` will warn that it couldn't restore it -
run as root if those files matter to your cover.

`status` also prints **environment intel** that changes how you should operate:

- `auditd is RUNNING` - kernel audit rules see everything; consider `auditctl -e 0` first
- `journald detected` - the binary journal needs the `journald` subcommand (not covered by snapshot)
- `swap is ACTIVE` - memory fragments are hitting disk; consider `swapoff -a` during the session
- `utmpdump available` - confirms surgical login-record mode for `finish`

---

## Command reference

### `start`

Snapshot all known trace files. Safe to run repeatedly (already-snapshotted files are skipped).

```bash
slytherin start
```

### `get <path>`

Record the pre-state of one specific file mid-session (anything outside the
known-trace list: configs, web roots, binaries you'll swap).

```bash
slytherin get /etc/passwd
```

### `finish`

Revert all snapshotted files (contents **and** atime/mtime), remove `slytherin`
lines from shell histories, then overwrite the session blobs with random bytes
and delete the session directory.

```bash
slytherin finish              # revert everything
slytherin finish --discard    # shred the session WITHOUT restoring (e.g. aborting a bad run)
slytherin finish --selfdestruct  # also shred the slytherin binary itself when leaving
```

On finish, utmp/wtmp/btmp get **record-level treatment** (if `utmpdump` is
installed): only records from *your* username/tty within the session window are
removed - logins by other users during your window survive. Without `utmpdump`,
those files fall back to full revert from the snapshot.

### `status`

Dry-run listing of trace files and current-user writability. Never modifies anything.

```bash
slytherin status
```

### `shred <paths...>`

Multi-pass random-overwrite, optional final zero pass, then unlink - the
file-recovery-defeating delete.

```bash
slytherin shred /tmp/payload -n 5 -z          # 5 random passes + zero pass, then delete
slytherin shred /var/log/*.log --keep         # overwrite in place, keep the file
slytherin shred ./exfil.tar.gz ./notes.md     # multiple paths, default 3 passes
```

### `mace <paths...>`

Rewrite file timestamps (atime/mtime). `-v` views current times, `-r` recurses a
directory tree, `--from` clones a donor file's timestamps
(blend your files in with siblings instead of picking a date). On
Linux, **ctime (inode change time) is not userspace-settable** - the tool
prints the exact `debugfs` command for ext4 if you need it.

```bash
slytherin mace /opt/implant -t "2024-03-01 09:15:00"
slytherin mace /opt/implant --from /usr/bin/ssh             # clone a legit binary's times
slytherin mace /opt/implant -t "2024-03-01 09:15:00" -r    # whole tree
slytherin mace /opt/implant -v                              # inspect current times
```

```console
$ slytherin mace ./svc -v
  ./svc
    Modified : Sat Jun 15 08:30:00 2019
    Accessed : Sat Jun 15 08:30:00 2019
    Changed  : Tue Sep  8 04:19:01 2026
```

### `journald`

Trim the systemd binary journal - the one trace surface a file snapshot **cannot**
cover. `--rotate` forces the current journal file to archive, `--vacuum-time`
then removes archived entries older than the given age:

```bash
slytherin journald --vacuum 1s      # effectively clears all archived entries
slytherin journald --vacuum 5min    # keep the last 5 minutes only
```

Requires root. Note: vacuum trims the **local** journal only - logs already
forwarded to a central SIEM/aggregator are unaffected, and the sudden size drop
is observable to anyone watching journal size.

### `changed`

Coverage check before `finish`: walk common dirs and list every file modified
or meta-changed (ctime) since the session started - i.e. everything *you*
touched that the snapshot doesn't already cover.

```bash
slytherin changed                       # default: /etc /opt /srv /var/www /root /home
slytherin changed --dir /var/backups    # scan specific dirs
```

For each hit, either `get` it now (so `finish` reverts it) or `mace` it.

### `pkg`

Debian-family (dpkg) package tracking. `start` records a baseline of every
installed package; `pkg` diffs the live package list against that baseline and
shows exactly what the session added - the package itself **and** every
dependency that came along (deps are session-installed too, so they show up in
the same diff).

```bash
slytherin pkg              # list packages installed during this session
slytherin pkg --print      # just print the purge command for review
slytherin pkg --remove     # apt-get purge the whole session set, deps included
```

`finish` warns if session-installed packages are still present, so a "clean"
finish can't silently leave the tooling you dropped on the box in `dpkg -l`.
The apt/dpkg install-history logs (`/var/log/apt/*`, `/var/log/dpkg.log*`,
`/var/log/aptitude*`, `/var/log/eipp.log*`) are in the trace list and get
reverted by `finish` regardless. Requires dpkg (Debian-family); on other
package systems the baseline step is skipped with a warning.

### `free`

Overwrite unallocated disk space so deleted-file remnants can't be carved.

```bash
slytherin free                    # fill /tmp's filesystem
slytherin free --dir /var         # fill a specific mount
slytherin free --mb 512           # cap the wipe at 512 MB
```

### `selftest`

Built-in verification - exercises snapshot/revert, mtime revert, shred+zero, and
session cleanup in a temp dir. Run it after any edit or on an unfamiliar box
before trusting a session to it.

```bash
slytherin selftest
[slytherin] [+] selftest PASS (snapshot/revert, mtime revert, shred+zero, utmp filter, dpkg parse, session cleanup)
```

---

## What counts as a "trace file"

The built-in list (extend it in `build_paths()`):

- **System logs** - `auth.log`, `syslog`, `daemon.log`, `kern.log`, `messages`,
  `secure`, `mail.log`/`maillog`, `cron.log`, `boot.log`, `dmesg`, `mysqld.log`,
  `yum.log`, `audit/*.log`
- **Firewall** - UFW logs (`/var/log/ufw.log` + rotations) - every LAN connection you make
- **Package manager** - apt `history.log`/`term.log`, `dpkg.log`, `aptitude`, `eipp.log`
- **Web/database servers** - `httpd/*`, `lighttpd/*`, `apache2/*`, XAMPP
  (`/opt/lampp/logs/*`), MySQL/MariaDB (`/var/log/mysql/*`, `/var/log/mariadb/*`,
  XAMPP `/opt/lampp/var/mysql/*.err`)
- **Login records** - `wtmp`, `btmp`, `utmp` (`last`, `lastb`, `who` read these;
  surgically stripped per-record on `finish`), `lastlog`, `faillog`
- **Shell histories** - `.bash_history`, `.zsh_history`, `.sh_history`,
  `.python_history`, `.node_repl_history`, `.mysql_history`, `.lesshst`, `.viminfo`
  - for **every user on the box** (`/home/*` and `/root`), not just the one you
  landed as; pivoting or `su` leaves traces in their homes too
- **Remote-host traces** - `~/.ssh/known_hosts` for every user (which hosts
  *you* connected to), AnyDesk logs (`/var/log/anydesk*`, `*/.anydesk/*`),
  NFS/CIFS mount history (`/run/mount/utab`)
- **Desktop / GUI** - `recently-used.xbel` and gnome-shell state for every user

`finish` reverts these wholesale; shell histories additionally get every line
containing `slytherin` stripped as a fallback.

---

## OPSEC notes - read before operating

- **Reverting is blunt on shared hosts.** `finish` restores log files to their
  `start` state - if other processes wrote log lines during your window, those
  get reverted too. On busy multi-tenant boxes, prefer surgical `get` on the
  specific files you touched over a full-session blanket restore.
- **The live shell flushes history on exit.** `finish` scrubs the history file,
  but the shell you're inside appends its in-memory buffer afterwards. Close out
  with `history -c && unset HISTFILE` (bash) or exit from a fresh shell.
- **`start` immediately after shell access**, not after your first command -
  everything you ran before `start` is not covered.
- **Timestamps of your own binary.** `mace` the slytherin copy itself if you
  staged it onto the box (and `shred` it when leaving - the session dir already
  self-destructs).
- **ctime is your residue on ext4.** Reading a file updates atime (covered),
  but any change updates ctime, which userspace cannot forge. The `debugfs`
  path (printed by `mace`) requires unmounting or an offline image.
- **Journald hosts.** The binary journal under `/var/log/journal/` is NOT
  snapshotted (too large, binary format). Use `slytherin journald --vacuum 1s`
  after acting - and remember forwarded copies live on the SIEM regardless.
- **SSD wear-leveling** means `shred`/`free` cannot guarantee erasure on flash -
  they defeat naive recovery, not a chip-off lab. `shred` renames files to random
  names before unlinking (defeats filename recovery from directory entries and
  the ext4 journal) and drops the page cache after every pass.
- **The kernel layer is out of scope.** Hiding processes/files/connections from
  the *live* system is LKM rootkit territory; slytherin deliberately stays
  userspace and portable.

## Design notes

- Single file, stdlib only - carry it with one `curl`.
- Session state: `/tmp/.slytherin-<uid>/` (mode `0700`), contents randomized
  before deletion on `finish`.
- Files >64 MB are skipped by the snapshotter (`MAX_SNAP`) so a stray journal
  file can't silently turn your session dir into a copy of the disk.

## MITRE ATT&CK

T1070 (Indicator Removal) - .002 Clear Linux Logs, .004 File Deletion, .006 Timestomping.
