#!/usr/bin/env python3

import argparse
import dataclasses
import datetime as dt
import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import signal


def _now_utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _run_dir(base: Path) -> Path:
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    return base / ts


def _mkdirs(run_dir: Path) -> None:
    (run_dir / "screenshots").mkdir(parents=True, exist_ok=True)


def _ps_sample(pid: int) -> dict:
    # %cpu is per-process and can exceed 100 on multi-core systems.
    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "%cpu=", "-o", "rss="],
            text=True,
        ).strip()
        if not out:
            return {}
        parts = out.split()
        if len(parts) < 2:
            return {}
        return {
            "cpu_percent": float(parts[0]),
            "rss_kb": int(parts[1]),
        }
    except Exception:
        return {}


def _screenshot(out_path: Path) -> bool:
    try:
        subprocess.run(["screencapture", "-x", str(out_path)], check=True)
        return True
    except Exception:
        return False


@dataclasses.dataclass
class TickState:
    last_frames: int = 0
    last_t: float = 0.0


def _safe_int(x, default=0) -> int:
    try:
        return int(x)
    except Exception:
        return default


def _scan_dims(buf: bytes, limit: int = 8) -> list[tuple[int, int, int]]:
    # Heuristic: find little-endian u32 pairs that look like WxH.
    out: list[tuple[int, int, int]] = []

    def is_dim(v: int) -> bool:
        return 640 <= v <= 8192

    for off in range(0, max(0, len(buf) - 8), 4):
        w = int.from_bytes(buf[off : off + 4], "little", signed=False)
        h = int.from_bytes(buf[off + 4 : off + 8], "little", signed=False)
        if is_dim(w) and is_dim(h):
            out.append((off, w, h))
            if len(out) >= limit:
                break
    return out


def _top_offsets(hist: dict, top_n: int = 8) -> list[dict]:
    items: list[dict] = []
    for k, v in (hist or {}).items():
        try:
            items.append({"off": k, "count": int(v.get("count", 0)), "meta": v.get("meta")})
        except Exception:
            continue
    items.sort(key=lambda x: x.get("count", 0), reverse=True)
    return items[: max(0, int(top_n))]


def _extract_struct_offsets_payload(suggestions) -> dict | None:
    # Accept either:
    # 1) {"payload": {...}, "suggestions": {...}}
    # 2) legacy: {"reblur_diffuse": {"payload": {...}}, ...}
    if not isinstance(suggestions, dict):
        return None
    if "payload" in suggestions and isinstance(suggestions["payload"], dict):
        return suggestions["payload"]
    payload: dict = {}
    for _k, v in suggestions.items():
        if isinstance(v, dict) and isinstance(v.get("payload"), dict):
            payload.update(v["payload"])
    return payload or None


def main() -> int:
    ap = argparse.ArgumentParser(description="MetalFX telemetry supervisor (2s polling + screenshots)")
    ap.add_argument("--pid", type=int, default=0, help="Attach to an existing PID")
    ap.add_argument("--spawn", type=str, default="", help="Spawn a process (path to game binary)")
    ap.add_argument("--script", type=str, default=str(Path(__file__).with_name("metalfx_hooks.js")))
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--duration-s", type=float, default=0.0, help="If >0, stop after N seconds")
    ap.add_argument("--runs", type=str, default=str(Path(__file__).resolve().parent.parent / "runs"))
    ap.add_argument("--no-screenshots", action="store_true")
    ap.add_argument("--arg-logging", action="store_true")
    ap.add_argument(
        "--pipeline-trace",
        action="store_true",
        help="Trace Metal shader/pipeline creation + compute dispatches (denoiser discovery)",
    )
    ap.add_argument(
        "--pipeline-trace-verbose",
        action="store_true",
        help="Trace all compute dispatches (very noisy)",
    )
    ap.add_argument(
        "--pipeline-trace-pso-allow",
        type=str,
        default="",
        help="Comma-separated PSO pointer strings to allow (filters pipeline trace to these pipelines)",
    )
    ap.add_argument(
        "--pipeline-trace-pso-skip",
        type=str,
        default="",
        help="Comma-separated PSO pointer strings to tag as skip candidates (no dispatch mutation; safe profiling only)",
    )
    ap.add_argument("--replace", action="store_true", help="Enable replaceEnabled in Frida script")
    ap.add_argument("--motion-mode", type=int, default=-1, help="Set motion vector mode (e.g. 0 passthrough, 1 NDC->pixels)")
    ap.add_argument("--flip-y", action="store_true", help="Flip motion Y when motion mode enabled")
    ap.add_argument("--autocapture", action="store_true", help="Enable Frida ObjC autocapture for cmdBuffer/motion/depth")
    ap.add_argument("--autocapture-min-count", type=int, default=0, help="Autocapture minCount threshold")
    ap.add_argument("--autocapture-motion-index", type=int, default=-2, help="Autocapture motion index filter (-1 disables; -2 = default)")
    ap.add_argument("--autocapture-depth-index", type=int, default=-2, help="Autocapture depth index filter (-1 disables; -2 = default)")
    ap.add_argument("--skip-original", action="store_true", help="Skip calling original NRD when MetalFX reports used=true")
    ap.add_argument("--struct-scan", action="store_true", help="Enable x1 struct scanning and histogram aggregation")
    ap.add_argument("--struct-scan-max-bytes", type=int, default=0x300, help="Max bytes to scan in x1 structs")
    ap.add_argument("--struct-scan-dump-every-s", type=float, default=10.0, help="Dump struct scan summary to structscan.json every N seconds (0 disables)")
    ap.add_argument("--struct-scan-clear-on-dump", action="store_true", help="Clear histogram after each dump")
    ap.add_argument("--struct-offsets-file", type=str, default="", help="JSON file with setStructOffsets() payload")
    ap.add_argument("--ab-toggle-s", type=float, default=0.0, help="If >0, toggle replacement on/off every N seconds (A/B)")
    args = ap.parse_args()

    if (args.pid == 0) == (args.spawn == ""):
        print("Provide exactly one of --pid or --spawn", file=sys.stderr)
        return 2

    script_path = Path(args.script).resolve()
    if not script_path.exists():
        print(f"Frida script not found: {script_path}", file=sys.stderr)
        return 2

    runs_base = Path(args.runs).resolve()
    run_dir = _run_dir(runs_base)
    _mkdirs(run_dir)

    telemetry_path = run_dir / "telemetry.jsonl"
    events_path = run_dir / "events.jsonl"
    print(f"run_dir: {run_dir}")
    print(f"telemetry: {telemetry_path}")
    print(f"events: {events_path}")

    try:
        import frida  # type: ignore
    except Exception as e:
        print("Python frida module not available.", file=sys.stderr)
        print("Use the repo venv:", file=sys.stderr)
        print("  .venv/bin/python scripts/supervisor.py ...", file=sys.stderr)
        print(f"error: {e}", file=sys.stderr)
        return 2

    device = frida.get_local_device()

    if args.spawn:
        argv = [args.spawn]
        pid = device.spawn(argv)
        session = device.attach(pid)
        device.resume(pid)
        print(f"spawned pid={pid}")
    else:
        pid = args.pid
        session = device.attach(pid)
        print(f"attached pid={pid}")

    with open(script_path, "r", encoding="utf-8") as f:
        source = f.read()

    script = session.create_script(source)

    messages_path = run_dir / "frida_messages.jsonl"

    def _on_message(message, data):
        try:
            rec = {
                "wall": _now_utc_iso(),
                "pid": pid,
                "message": message,
            }
            if data is not None:
                rec["data_len"] = len(data)
            messages_path.write_text(messages_path.read_text(encoding="utf-8") + json.dumps(rec) + "\n", encoding="utf-8")
        except Exception:
            try:
                with open(messages_path, "a", encoding="utf-8") as mf:
                    mf.write(json.dumps({"wall": _now_utc_iso(), "pid": pid, "message": message}) + "\n")
            except Exception:
                pass

    try:
        script.on("message", _on_message)
    except Exception:
        pass
    script.load()

    # Give the script a moment to register rpc.exports (some environments are racy right after load).
    time.sleep(0.25)

    if hasattr(script, "exports_sync"):
        exports = script.exports_sync
    else:
        exports = script.exports

    # Sanity-check that RPC exports are available; if not, we won't get telemetry.
    try:
        _ = exports.get_stats()
    except Exception as e:
        print(f"[supervisor] ERROR: frida RPC exports not available (get_stats failed): {e}", file=sys.stderr)

    # Clear any pre-existing event backlog *before* applying toggles so we keep
    # events generated by our toggle changes (e.g. pipeline_trace_status).
    try:
        exports.clear_events()
    except Exception:
        pass

    # Apply initial toggles
    try:
        exports.set_arg_logging(bool(args.arg_logging))
    except Exception:
        pass
    if bool(args.pipeline_trace) or bool(args.pipeline_trace_verbose):
        # Set allowlist first so it applies during hook install.
        if str(args.pipeline_trace_pso_allow).strip():
            try:
                psos = [p.strip() for p in str(args.pipeline_trace_pso_allow).split(",") if p.strip()]
                exports.set_pipeline_trace_pso_allowlist(psos)
            except Exception:
                pass
        if str(args.pipeline_trace_pso_skip).strip():
            try:
                psos = [p.strip() for p in str(args.pipeline_trace_pso_skip).split(",") if p.strip()]
                exports.set_pipeline_trace_pso_skiplist(psos)
            except Exception:
                pass
        try:
            exports.set_pipeline_trace_enabled(True, bool(args.pipeline_trace_verbose))
        except Exception:
            pass
    try:
        exports.set_replace_enabled(bool(args.replace))
    except Exception:
        pass
    try:
        exports.set_skip_original_when_used(bool(args.skip_original))
    except Exception:
        pass
    if args.motion_mode >= 0:
        try:
            exports.set_motion_vector_mode(int(args.motion_mode), bool(args.flip_y))
        except Exception:
            pass

    if args.autocapture:
        try:
            exports.set_auto_capture_enabled(True)
        except Exception:
            pass

    if args.struct_scan:
        try:
            exports.set_struct_scan_enabled(True, int(args.struct_scan_max_bytes))
        except Exception:
            pass

    if args.struct_offsets_file:
        try:
            p = Path(args.struct_offsets_file).expanduser().resolve()
            payload = json.loads(p.read_text(encoding="utf-8"))
            exports.set_struct_offsets(payload)
            print(f"applied struct offsets from: {p}")
        except Exception as e:
            print(f"failed to apply struct offsets: {e}", file=sys.stderr)

        try:
            filt = {}
            if args.autocapture_min_count > 0:
                filt["minCount"] = int(args.autocapture_min_count)
            if args.autocapture_motion_index != -2:
                filt["motionIndex"] = int(args.autocapture_motion_index)
            if args.autocapture_depth_index != -2:
                filt["depthIndex"] = int(args.autocapture_depth_index)
            if filt:
                exports.set_auto_capture_filters(filt)
        except Exception:
            pass

    tick = TickState(last_frames=0, last_t=time.monotonic())
    start_t = tick.last_t

    replace_state = bool(args.replace)
    last_toggle_t = start_t

    last_struct_dump_t = start_t

    stop = {"flag": False}

    def _handle_sigint(_sig, _frame):
        stop["flag"] = True

    signal.signal(signal.SIGINT, _handle_sigint)
    signal.signal(signal.SIGTERM, _handle_sigint)

    with open(telemetry_path, "a", encoding="utf-8") as tf, open(events_path, "a", encoding="utf-8") as ef:
        while not stop["flag"]:
            t0 = time.monotonic()
            if args.duration_s and (t0 - start_t) >= float(args.duration_s):
                break
            # Optional A/B toggle
            if args.ab_toggle_s and (t0 - last_toggle_t) >= args.ab_toggle_s:
                replace_state = not replace_state
                last_toggle_t = t0
                try:
                    exports.set_replace_enabled(replace_state)
                except Exception:
                    pass
                try:
                    exports.signal_camera_cut()
                except Exception:
                    pass
            wall = _now_utc_iso()
            dt_s = t0 - tick.last_t
            tick.last_t = t0

            stats = {}
            try:
                stats = exports.get_stats()
            except Exception:
                stats = {}

            frames = _safe_int(stats.get("totalFrames", 0))
            fps = None
            if dt_s > 0:
                fps = (frames - tick.last_frames) / dt_s
            tick.last_frames = frames

            events = []
            try:
                events = exports.get_events()
            except Exception:
                events = []

            if events:
                for ev in events:
                    ef.write(json.dumps({"wall": wall, "pid": pid, **ev}) + "\n")
                ef.flush()
                try:
                    exports.clear_events()
                except Exception:
                    pass

            nrd_inputs_hex = None
            try:
                nrd_inputs_hex = exports.get_nrd_inputs_snapshot(256)
            except Exception:
                nrd_inputs_hex = None

            nrd_inputs_b64 = None
            nrd_dims = None
            try:
                nrd_inputs_b64 = exports.get_nrd_inputs_snapshot_b64(512)
                if nrd_inputs_b64 and isinstance(nrd_inputs_b64, dict) and "b64" in nrd_inputs_b64:
                    raw = base64.b64decode(nrd_inputs_b64["b64"].encode("ascii"), validate=False)
                    nrd_dims = _scan_dims(raw)
            except Exception:
                nrd_inputs_b64 = None
                nrd_dims = None

            native_perf = None
            try:
                native_perf = exports.get_native_perf()
            except Exception:
                native_perf = None

            pipeline_trace = None
            if bool(args.pipeline_trace) or bool(args.pipeline_trace_verbose):
                try:
                    pipeline_trace = exports.get_pipeline_trace_summary()
                except Exception:
                    pipeline_trace = None

            autocap_state = None
            if args.autocapture:
                try:
                    autocap_state = exports.get_auto_capture_state()
                except Exception:
                    autocap_state = None

            structscan_top = None
            structscan_suggestions = None
            if args.struct_scan and args.struct_scan_dump_every_s:
                if (t0 - last_struct_dump_t) >= float(args.struct_scan_dump_every_s):
                    last_struct_dump_t = t0
                    try:
                        summary = exports.get_struct_scan_summary()
                        (run_dir / "structscan.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
                        hist = summary.get("hist", {}) if isinstance(summary, dict) else {}
                        structscan_top = {
                            "reblur_diffuse_x1": _top_offsets(hist.get("reblur_diffuse_x1", {})),
                            "sigma_shadow_x1": _top_offsets(hist.get("sigma_shadow_x1", {})),
                            "reblur_diffuse_specular_x1": _top_offsets(hist.get("reblur_diffuse_specular_x1", {})),
                        }

                        try:
                            structscan_suggestions = exports.get_struct_scan_suggestions()
                            (run_dir / "struct_offsets_suggested.json").write_text(json.dumps(structscan_suggestions, indent=2), encoding="utf-8")
                            payload = _extract_struct_offsets_payload(structscan_suggestions)
                            if payload:
                                (run_dir / "struct_offsets_payload.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
                        except Exception:
                            structscan_suggestions = None

                        if args.struct_scan_clear_on_dump:
                            try:
                                exports.clear_struct_scan_summary()
                            except Exception:
                                pass
                    except Exception:
                        structscan_top = None
                        structscan_suggestions = None

            proc = _ps_sample(pid)

            screenshot_path = None
            if not args.no_screenshots:
                screenshot_name = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".png"
                screenshot_path = str((run_dir / "screenshots" / screenshot_name).resolve())
                ok = _screenshot(Path(screenshot_path))
                if not ok:
                    screenshot_path = None

            record = {
                "wall": wall,
                "uptime_s": t0 - start_t,
                "pid": pid,
                "dt_s": dt_s,
                "fps": fps,
                "stats": stats,
                "process": proc,
                "native": native_perf,
                "pipeline_trace": pipeline_trace,
                "autocapture_state": autocap_state,
                "structscan_top": structscan_top,
                "structscan_suggestions": structscan_suggestions,
                "nrd_inputs_256": nrd_inputs_hex,
                "nrd_inputs_b64": nrd_inputs_b64,
                "nrd_dims": nrd_dims,
                "screenshot": screenshot_path,
                "replace": replace_state,
                "arg_logging": bool(args.arg_logging),
                "motion_mode": args.motion_mode,
                "motion_flip_y": bool(args.flip_y),
                "autocapture": bool(args.autocapture),
                "autocapture_min_count": args.autocapture_min_count,
                "autocapture_motion_index": args.autocapture_motion_index,
                "autocapture_depth_index": args.autocapture_depth_index,
                "ab_toggle_s": args.ab_toggle_s,
            }

            tf.write(json.dumps(record) + "\n")
            tf.flush()

            # Sleep to maintain interval
            elapsed = time.monotonic() - t0
            sleep_s = args.interval - elapsed
            if sleep_s > 0:
                time.sleep(sleep_s)

    try:
        script.unload()
    except Exception:
        pass
    try:
        session.detach()
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
