#!/usr/bin/env python3
"""resolve_page_agent — speedcolors' Python sidecar.

Reports the DaVinci Resolve version and current page as a JSON line on stdout.
Uses Resolve's official scripting bridge (fusionscript.so), which is a CPython
extension — hence this tiny sidecar instead of doing it in Swift.

Usage:
    resolve_page_agent.py --once      print one JSON line and exit
    resolve_page_agent.py --watch     stream JSON lines on page change
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import time

DEFAULT_LIB = (
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/"
    "Fusion/fusionscript.so"
)


def load_fusionscript():
    lib = os.environ.get("RESOLVE_SCRIPT_LIB", DEFAULT_LIB)
    if not os.path.exists(lib):
        raise FileNotFoundError(f"fusionscript not found: {lib}")
    loader = importlib.machinery.ExtensionFileLoader("fusionscript", lib)
    spec = importlib.util.spec_from_loader("fusionscript", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def emit(obj):
    print(json.dumps(obj), flush=True)


def once():
    fusionscript = load_fusionscript()
    resolve = fusionscript.scriptapp("Resolve")
    if resolve is None:
        emit({"error": "resolve-not-running"})
        return 0  # a stopped Resolve is a valid answer, not a sidecar failure
    emit({
        "ok": True,
        "version": resolve.GetVersionString(),
        "page": resolve.GetCurrentPage(),
    })
    return 0


def watch(interval=0.25):
    # Emit the FIRST observation unconditionally — even "Resolve not
    # reachable" — so the daemon never sits blind waiting for a change that
    # only comes when the page actually flips. Recover by reloading the
    # extension after a failure: a fusionscript handle can go stale when
    # Resolve quits and relaunches.
    fusionscript = None
    resolve = None
    last = None
    first = True
    while True:
        try:
            if fusionscript is None:
                fusionscript = load_fusionscript()
            if resolve is None:
                resolve = fusionscript.scriptapp("Resolve")
            page = resolve.GetCurrentPage() if resolve else None
        except Exception:
            fusionscript = None
            resolve = None
            page = None
        if first or page != last:
            emit({"ok": page is not None, "page": page, "t": time.time()})
            last = page
            first = False
        time.sleep(interval)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        watch()
    else:
        sys.exit(once())
