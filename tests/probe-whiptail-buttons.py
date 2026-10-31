#!/usr/bin/env python3
"""probe-whiptail-buttons.py — measure which colour whiptail paints on the FOCUSED button.

Runs whiptail in a pseudo-terminal with marker colours, presses Tab then Enter by script, and
reads the colour codes actually drawn around <Ok>/<Cancel>. No eyeballing: it reports which
newt colourset (button / compactbutton / actbutton) this box's newt uses for the focused and
unfocused buttons, and whether the kiss-console palette highlights the right one.

Usage:  python3 tests/probe-whiptail-buttons.py      (or /usr/libexec/platform-python on EL8)
"""
import os, pty, re, select, shutil, subprocess, sys, time

if not shutil.which("whiptail"):
    sys.exit("whiptail not installed")

# Marker palette: each colourset gets a unique background so we can tell them apart.
MARKERS = {"button": "41", "actbutton": "42", "compactbutton": "44"}   # red / green / blue
MARK_ENV = ("root=,black\nwindow=white,black\nlistbox=white,black\nsellistbox=white,black\n"
            "actsellistbox=white,black\n"
            "button=white,red\nactbutton=white,green\ncompactbutton=white,blue\n")


def run(colors, tabs):
    """Press Tab `tabs` times, then Enter. Return (screen after the last Tab, exit code)."""
    env = dict(os.environ, TERM="xterm", NEWT_COLORS=colors)
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("whiptail", ["whiptail", "--notags", "--menu", "probe", "14", "50", "3",
                                "a", "Row one", "b", "Row two"], env)

    def drain(t):
        out, end = b"", time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    break
        return out

    drain(1.0)
    snap = b""
    for _ in range(tabs):
        os.write(fd, b"\t")
        snap = drain(0.6)
    os.write(fd, b"\r")
    drain(0.3)
    _, st = os.waitpid(pid, 0)
    return snap.decode("latin1"), (os.WEXITSTATUS(st) if os.WIFEXITED(st) else -1)


def bg_before(screen, word):
    i = screen.find("<" + word + ">")
    if i < 0:
        return None
    codes = [c for g in re.findall(r"\x1b\[([0-9;]*)m", screen[:i])[-3:] for c in g.split(";") if c]
    bgs = [c for c in codes if c.startswith("4") and len(c) == 2]
    return bgs[-1] if bgs else None


name = {v: k for k, v in MARKERS.items()}
print("newt:", subprocess.run(["sh", "-c", "rpm -q newt 2>/dev/null || dpkg-query -W -f='${Version}' libnewt0.52 2>/dev/null"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True).stdout.strip() or "unknown")   # py3.6 (EL8)

screen, rc = run(MARK_ENV, 2)          # focus on Cancel; Ok is redrawn unfocused
focused, unfocused = bg_before(screen, "Cancel"), bg_before(screen, "Ok")
print(f"After 2x Tab, Enter activated: {'Ok' if rc == 0 else 'Cancel'}  (expected Cancel)")
print(f"  focused   button drawn with: {name.get(focused, focused)}")
print(f"  unfocused button drawn with: {name.get(unfocused, unfocused)}")

# Now the real kiss-console palette.
pal_src = "/usr/local/lib/kiss-backup/console.sh"
if not os.path.exists(pal_src):
    pal_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "console", "console.sh")
m = re.search(r"export NEWT_COLORS='\n(.*?)\n'", open(pal_src).read(), re.S)
if m:
    pal = m.group(1)
    screen, rc = run(pal, 2)
    f, u = bg_before(screen, "Cancel"), bg_before(screen, "Ok")
    ok = rc == 1 and f is not None and f != u
    print(f"kiss-console palette ({pal_src}): focused bg={f} unfocused bg={u} -> "
          + ("CORRECT: the focused button is the highlighted one" if ok else "WRONG: highlight does not follow focus"))
