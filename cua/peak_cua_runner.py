"""Peak's Cua child: ONE menu-item invoke through cua-driver (trycua, MIT), started only by Peak's DesktopPresser.

Peak spawns this with ~/ForceIQ/.venv-peak-cua/bin/python -I -B, in its own process group, with a minimal environment,
after its production guard, PressGuard, an approval card's Run tap and a STOP check. STOP kills the whole group.

stdin: one JSON line {"op": "invoke_menu", "pid": int, "bundle_id": str, "menu_path": [menu, "Code Window"], "ticket": str}
stdout: one JSON line {"ok": bool, "detail": str, "effect"?: str, "route"?: str, "ms": int}. No client names, no window
titles, no captures: only the pid, the bundle id and the menu path that Peak sent.

Everything below is refused (exit 3) BEFORE cua_driver is imported: the flag off (FORCEIQ_PEAK_CUA_LIVE != "1"), TMPDIR
outside ~/ForceIQ/peak-tmp/cua, a malformed request, production FLOW (bundle com.forceiq.flowai any case, a pid in
FORCEIQ_PEAK_PROTECTED_PIDS), or a menu path that isn't exactly [<menu>, "Code Window"]. After the import the live
process is checked again (its bundle id and app path, never production) and Cua runs embedded (never the CuaDriver.app
daemon). Missing Accessibility: exit 4, nothing requested, nothing pressed. Only list_apps, list_windows and invoke_menu
are ever called. FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS (smoke only) waits that long after the checks, before the import,
so a live STOP can be proven against an in-flight child.
"""
import json
import os
import sys
import time

FLAG = "FORCEIQ_PEAK_CUA_LIVE"
PROD_BUNDLES = {"com.forceiq.flowai"}
PROD_APP = "/applications/flow.app"
ITEM = "Code Window"
HOLD = "FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS"


def emit(ok, detail, code, t0, **extra):
    out = {"ok": ok, "detail": detail, "ms": int((time.monotonic() - t0) * 1000)}
    out.update({k: v for k, v in extra.items() if v is not None})
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    return code


def protected_pids(env):
    raw = env.get("FORCEIQ_PEAK_PROTECTED_PIDS", "")
    out = set()
    for p in raw.replace(",", " ").split():
        if p.strip().isdigit() and int(p) > 0:
            out.add(int(p))
    return out


def is_prod_bundle(b):
    return (b or "").strip().lower() in PROD_BUNDLES


def is_prod_path(p):
    if not p:
        return False
    n = os.path.normpath(p).lower()
    return n == PROD_APP or n.startswith(PROD_APP + "/")


def precheck(req, env):
    """None = may import Cua. Otherwise why not (nothing imported, nothing pressed)."""
    if env.get(FLAG) != "1":
        return "refused: the Cua flag is off (%s != 1); Cua not imported" % FLAG
    tmp = os.path.realpath(env.get("TMPDIR", "/tmp"))
    want = os.path.realpath(os.path.expanduser("~/ForceIQ/peak-tmp/cua"))
    if tmp != want and not tmp.startswith(want + os.sep):
        return "refused: TMPDIR must be ~/ForceIQ/peak-tmp/cua"
    if not isinstance(req, dict) or req.get("op") != "invoke_menu":
        return "refused: unknown request"
    pid, bundle, path = req.get("pid"), req.get("bundle_id"), req.get("menu_path")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return "refused: not a pid"
    if not isinstance(bundle, str) or not bundle.strip():
        return "refused: no bundle id"
    if is_prod_bundle(bundle):
        return "refused: production FLOW (bundle %s)" % bundle.strip()
    if pid in protected_pids(env):
        return "refused: pid %d is protected (production FLOW)" % pid
    if not (isinstance(path, list) and len(path) == 2 and all(isinstance(x, str) for x in path)
            and path[0].strip() and path[1] == ITEM):
        return "refused: the menu path must be exactly [<menu>, '%s']" % ITEM
    if not isinstance(req.get("ticket"), str) or not req["ticket"]:
        return "refused: no approval ticket"
    return None


async def invoke(req, env, t0):
    import cua_driver as cd

    perm = cd.current_mac_os_permission_status()
    if not perm.accessibility:
        return emit(False, "Accessibility is not granted to Peak; nothing requested, nothing pressed", 4, t0)
    driver = cd.CuaDriver.create(cd.DriverOptions(claude_code_compatibility=False), embedded=True)
    try:
        pid, bundle, path = req["pid"], req["bundle_id"], req["menu_path"]
        apps = await driver.list_apps(cd.ListAppsInput())
        live = [a for a in apps.apps if a.running and a.pid == pid]
        if len(live) != 1:
            return emit(False, "refused: pid %d is not one running app" % pid, 3, t0)
        app = live[0]
        prot = protected_pids(env) | {a.pid for a in apps.apps if a.running and is_prod_bundle(a.bundle_id)}
        if pid in prot or is_prod_bundle(app.bundle_id) or is_prod_path(app.launch_path):
            return emit(False, "refused: pid %d is production FLOW" % pid, 3, t0)
        if app.bundle_id != bundle:
            return emit(False, "refused: pid %d is not %s" % (pid, bundle), 3, t0)
        wins = await driver.list_windows(cd.ListWindowsInput(pid=pid, on_screen_only=True))
        mine = [w for w in wins.windows if w.pid == pid and w.is_on_screen and not w.minimized]
        if not mine:
            return emit(False, "no on-screen window for pid %d; nothing pressed" % pid, 5, t0)
        front = sorted(mine, key=lambda w: (w.z_index if w.z_index is not None else 1 << 30))[0]
        res = await driver.invoke_menu(cd.InvokeMenuInput(pid=pid, window_id=front.window_id, path=path, session=None))
        act = getattr(res, "action", None)
        effect = str(act.effect).split(".")[-1].lower() if act is not None and getattr(act, "effect", None) is not None else None
        route = str(act.route).split(".")[-1].lower() if act is not None and getattr(act, "route", None) is not None else None
        if res.is_error:
            return emit(False, "cua-driver refused the menu invoke (%s); nothing pressed" % (res.error_code or "error"), 6, t0,
                        effect=effect, route=route)
        return emit(True, "cua-driver invoked %s in pid %d (window %d)" % (" > ".join(path), pid, front.window_id), 0, t0,
                    effect=effect, route=route)
    finally:
        await driver.shutdown()


def main(stdin=None, env=None):
    t0 = time.monotonic()
    env = dict(os.environ) if env is None else env
    stdin = sys.stdin if stdin is None else stdin
    try:
        req = json.loads(stdin.readline() or "null")
    except ValueError:
        req = None
    why = precheck(req, env)
    if why:
        return emit(False, why, 3, t0)
    hold = env.get(HOLD, "")
    if hold.isdigit():  # smoke-only: keeps the child in flight so a live STOP can land mid-run (capped at 10 s)
        time.sleep(min(int(hold), 10000) / 1000.0)
    import asyncio
    try:
        return asyncio.run(invoke(req, env, t0))
    except Exception as e:  # a Cua error never carries names: report its type only
        return emit(False, "cua-driver error (%s); nothing pressed" % type(e).__name__, 7, t0)


if __name__ == "__main__":
    sys.exit(main())
