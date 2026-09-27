"""Run the live matrix, or a key-free offline matrix with pending cells."""
from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from audio_fixtures import ensure_clips
from fallback import answer_turn
from live_ptt import LIVE_MODELS, api_key_from_env, build_client, run_push_to_talk
from vad_probe import probe_model

TESTS = ("push_to_talk_answered", "speech_detection_fired", "fallback_path")


def sdk_version() -> str:
    try:
        return importlib.metadata.version("google-genai")
    except importlib.metadata.PackageNotFoundError:
        return "unavailable"


def pending_matrix() -> dict[str, dict[str, dict[str, Any]]]:
    return {
        model: {
            test: {"status": "pending key", "latencies_ms": None}
            for test in TESTS
        }
        for model in LIVE_MODELS
    }


def _status_row(status: str, measurement: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": status,
        "latencies_ms": {
            key: value
            for key, value in measurement.items()
            if key.endswith("_ms") and isinstance(value, (int, float))
        },
        "booleans": {
            key: value
            for key, value in measurement.items()
            if isinstance(value, bool)
        },
    }


async def live_matrix(client: Any, clip: bytes) -> dict[str, dict[str, dict[str, Any]]]:
    matrix: dict[str, dict[str, dict[str, Any]]] = {}
    for model in LIVE_MODELS:
        rows: dict[str, dict[str, Any]] = {}
        try:
            ptt = await run_push_to_talk(client, model, clip)
            rows["push_to_talk_answered"] = _status_row(
                "answered" if ptt.answered else "not_answered", ptt.public()
            )
        except Exception:
            rows["push_to_talk_answered"] = {"status": "error", "latencies_ms": None}
        try:
            vad = await probe_model(client, model, clip)
            rows["speech_detection_fired"] = _status_row(
                "fired" if vad["triggered"] else "not_fired", vad
            )
        except Exception:
            rows["speech_detection_fired"] = {"status": "error", "latencies_ms": None}
        try:
            turn = await answer_turn(clip, client=client, live_model=model)
            public = turn.public()
            rows["fallback_path"] = {
                "status": public["path"],
                "latencies_ms": {
                    key: value for key, value in public["latencies"].items()
                    if key.endswith("_ms") and isinstance(value, (int, float))
                },
                "booleans": {
                    "transcript_in_arrived": public["transcript_in_arrived"],
                    "text_out_arrived": public["text_out_arrived"],
                    "audio_out": public["audio_out"],
                },
            }
        except Exception:
            rows["fallback_path"] = {"status": "error", "latencies_ms": None}
        matrix[model] = rows
    return matrix


def write_report(path: Path, result: dict[str, Any], fixture_info: dict[str, Any]) -> None:
    lines = [
        "# Live voice spike report",
        "",
        "This report contains only statuses, booleans, counts, and latencies; it intentionally excludes audio and transcript content.",
        "",
        f"- Generated: `{result['generated_at']}` (America/New_York)",
        f"- google-genai: `{result['sdk_version']}`",
        f"- Key status: `{result['key_status']}`",
        f"- Fixture source: `{fixture_info['source']}`; PCM `{fixture_info['sample_rate']} Hz`, mono, 16-bit",
        f"- Offline suite: `{result['offline_suite']['status']}` ({result['offline_suite']['tests']} tests)",
        "",
        "| Model | Push-to-talk | Automatic speech detection | Fallback path |",
        "|---|---|---|---|",
    ]
    for model, cells in result["matrix"].items():
        lines.append(
            f"| `{model}` | `{cells['push_to_talk_answered']['status']}` | "
            f"`{cells['speech_detection_fired']['status']}` | `{cells['fallback_path']['status']}` |"
        )
    lines += [
        "",
        "A `pending key` cell is not a measurement. Run again with `GEMINI_API_KEY` set to collect live measurements.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_offline_suite() -> dict[str, Any]:
    """Run the deterministic fake-client suite and retain only its summary."""
    completed = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", str(HERE / "test_spike.py")],
        cwd=str(HERE),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return {"status": "passed" if completed.returncode == 0 else "failed", "tests": 6}


def run(args: argparse.Namespace) -> dict[str, Any]:
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    fixture_info = ensure_clips(output_dir)
    key_present = bool(api_key_from_env())
    result: dict[str, Any] = {
        "schema_version": 1,
        "generated_at": datetime.now().astimezone().isoformat(),
        "sdk_version": sdk_version(),
        "key_status": "available" if key_present else "pending key",
        "matrix": pending_matrix(),
        "offline_suite": run_offline_suite(),
    }
    if key_present and args.live:
        client = build_client()
        clip = (output_dir / "english.pcm").read_bytes()
        result["matrix"] = asyncio.run(live_matrix(client, clip))
    (output_dir / "results.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_report(output_dir / "REPORT.md", result, fixture_info)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the myAmericanDream live voice spike")
    parser.add_argument("--live", action="store_true", help="run network measurements when the env key is present")
    parser.add_argument("--output-dir", default=str(HERE))
    args = parser.parse_args()
    result = run(args)
    print(json.dumps({"key_status": result["key_status"], "sdk_version": result["sdk_version"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
