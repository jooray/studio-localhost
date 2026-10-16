"""Drive the sidecar exactly like the app does (JSON lines over stdio): generate, then extend.

usage: python tools/e2e.py <python-with-backend> <out-root> [backend-config-json]
"""
import json, subprocess, sys, time, os
from pathlib import Path

py, root = sys.argv[1], Path(sys.argv[2])
cfg = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {
    "backend": "mlx", "family": "yue2", "engine_dir": os.environ["STUDIO_MLX_ENGINE_DIR"]}
here = Path(__file__).resolve().parents[1]
env = {**os.environ, "PYTHONPATH": str(here), "MLX_ENABLE_TF32": "0", "PYTHONUNBUFFERED": "1"}
proc = subprocess.Popen([py, "-m", "studio_engine"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(root / "sidecar.log", "w"), text=True, env=env, bufsize=1)
n = 0
def call(cmd, **kw):
    global n; n += 1
    proc.stdin.write(json.dumps({"id": f"r{n}", "cmd": cmd, **kw}) + "\n"); proc.stdin.flush()
    while True:
        msg = json.loads(proc.stdout.readline())
        if msg.get("id") == f"r{n}":
            if not msg["ok"]: raise RuntimeError(msg["error"])
            return msg["result"]
        print("  evt", msg)
def wait(job):
    last = None
    while True:
        msg = json.loads(proc.stdout.readline())
        if msg.get("event") == "progress":
            key = (msg["stage"], msg["label"])
            if key != last or (msg.get("done") or 0) % 50 == 0 or msg["stage"] in ("nar", "vae"):
                print(f"  [{msg['elapsed']:7.1f}s] {msg['stage']:8s} {msg['label']} {msg.get('done')}/{msg.get('total')} {msg.get('unit') or ''}")
                last = key
        elif msg.get("event") == "job_done": return msg["result"]
        elif msg.get("event") == "job_failed": raise RuntimeError(msg["error"])
print(json.loads(proc.stdout.readline()))
print(call("configure", **cfg))
info = call("info"); print({k: info[k] for k in ("backend", "venv_ok", "versions") if k in info})
t = time.time()
gen = call("generate", job="g1", output_dir=str(root / "gen"), title="E2E test",
           style="upbeat indie pop, female vocal, acoustic guitar, bright",
           lyrics="[Verse]\nSunlight on the river\nWe are walking slow\n[Chorus]\nSing it now, sing it loud\nLet the morning glow\n",
           mode="off", seed=4242, precision="8bit", steps=8, max_seconds=25)
res = wait("g1"); print("GENERATE", round(time.time() - t, 1), "s", json.dumps({k: res[k] for k in ("audio_seconds", "truncated")}))
print("  timing", json.dumps({k: v for k, v in res["engine_timing"].items() if k != "load"}, default=str)[:600])
t = time.time()
call("extend", job="e1", source_dir=str(root / "gen"), output_dir=str(root / "ext"),
     style="upbeat indie pop, female vocal, acoustic guitar, bright",
     lyrics="[Verse]\nSunlight on the river\nWe are walking slow\n[Chorus]\nSing it now, sing it loud\nLet the morning glow\n",
     mode="off", section_start=max(0.0, res["audio_seconds"] - 10.0), section_end=None, add_seconds=15,
     seed=4243, precision="8bit", steps=8, crossfade=2.0)
ext = wait("e1"); print("EXTEND", round(time.time() - t, 1), "s", json.dumps({k: ext[k] for k in ("audio_seconds", "truncated", "seam", "section")}))
print("  timing", json.dumps({k: v for k, v in ext["engine_timing"].items() if k != "load"}, default=str)[:600])
print(call("stats", path=str(root / "gen/audio.flac")))
print(call("stats", path=str(root / "ext/audio.flac")))
call("shutdown")
