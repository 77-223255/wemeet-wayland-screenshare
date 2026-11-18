#!/usr/bin/env python3
"""
Patch Tencent Wemeet 3.26.10.401 for screen sharing over xdg-desktop-portal.

Only Hunk 0 is used: it moves the ScreenCast `Start` call into the
`onSelectSourcesResponse` callback. Wemeet's original code fires `Start`
right after `SelectSources` without waiting for the response, which fails on
backends that block inside `SelectSources` (xdg-desktop-portal-hyprland,
xdg-desktop-portal-wlr, ...).

Hunk 1a/1b (upstream colour-format tricks) are intentionally NOT included:
on xdg-desktop-portal-hyprland they cause colour shifts.

Offset source: Matheritasiv/wemeet-screenshare-patch (patch.py).

Usage:
    python3 patch.py [--dry-run] <wemeet dir, e.g. /opt/wemeet>

Exit code 0 = all hunks applied (or would apply), 1 = rejected.
"""

import argparse
import mmap
import os
import sys

TARGET = "bin/modules/screen_share/libscreen_share_module.so"

# Hunk 0: move `dbusStart()` from `dbusSelectSources()` into
# `onSelectSourcesResponse()` — fixes the SelectSources/Start race.
HUNK_0 = {
    0x43D2FA: (bytes.fromhex("00"), bytes.fromhex("5d")),
    0x43D331: (bytes.fromhex("88f7"), bytes.fromhex("60fb")),
    0x43D336: (
        bytes.fromhex("83c718488b8588f7ffff48"),
        bytes.fromhex("89fe4883c618e910000000"),
    ),
    0x43D357: (bytes.fromhex("0000"), bytes.fromhex("e208")),
    0x43DC38: (bytes.fromhex("e8c305d9"), bytes.fromhex("e9ecf6ff")),
}


def patch_file(path: str, dry_run: bool = False) -> int:
    if not os.path.isfile(path):
        print(f"[ERROR] not found: {path}", file=sys.stderr)
        return 2

    size = os.path.getsize(path)
    written = 0

    with open(path, "rb" if dry_run else "r+b") as fh:
        access = mmap.ACCESS_READ if dry_run else mmap.ACCESS_WRITE
        with mmap.mmap(fh.fileno(), 0, access=access) as mm:
            for offset, (old, new) in sorted(HUNK_0.items()):
                if offset + len(old) > size:
                    print(f"  [BOUNDS]   0x{offset:08x}: past end of file")
                    return 1
                actual = mm[offset:offset + len(old)]
                if actual != old:
                    state = "already patched" if actual == new[:len(actual)] else "MISMATCH"
                    print(f"  [{state}] 0x{offset:08x}: expected {old.hex()} got {actual.hex()}")
                    return 1
                print(f"  [OK]       0x{offset:08x}: {old.hex()} => {new.hex()}")
                if not dry_run:
                    mm[offset:offset + len(new)] = new
                    written += len(new)
            if written:
                mm.flush()

    print(f"  applied {len(HUNK_0)} site(s), {written} byte(s)" if not dry_run
          else f"  dry-run: {len(HUNK_0)} site(s) would apply")
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description="Patch Wemeet 3.26.10.401 screen share.")
    ap.add_argument("wemeet_dir", help="wemeet install dir (e.g. /opt/wemeet)")
    ap.add_argument("--dry-run", action="store_true", help="validate only")
    args = ap.parse_args()

    target = f"{args.wemeet_dir.rstrip('/')}/{TARGET}"
    print(f"target: {target}")
    rc = patch_file(target, dry_run=args.dry_run)
    sys.exit(rc)


if __name__ == "__main__":
    main()
