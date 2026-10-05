"""Small worker status routes. File uploads and downloads use native ComfyUI endpoints."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
from aiohttp import web
from server import PromptServer


@PromptServer.instance.routes.get("/startup_status")
async def startup_status(request):
    return web.json_response({"label": "ready", "ready": True, "eta_text": "", "detail": "H3 worker ready"})


@PromptServer.instance.routes.get("/gpu_stats")
async def gpu_stats(request):
    def query():
        result = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,power.draw,clocks.sm,pstate",
            "--format=csv,noheader,nounits"], capture_output=True, text=True, check=True, timeout=5)
        gpus = []
        for line in result.stdout.splitlines():
            used, total, power, clock, state = [v.strip() for v in line.split(",")]
            gpus.append({"memory_used_mb": int(used), "memory_total_mb": int(total),
                "power_text": f"{power}W", "clock_text": f"{clock}MHz", "perf_text": state})
        return gpus
    try:
        return web.json_response({"gpus": await asyncio.to_thread(query)})
    except (OSError, ValueError, subprocess.SubprocessError):
        return web.json_response({"gpus": []})


@PromptServer.instance.routes.get("/projectswift/h3/profile")
async def h3_profile(request):
    return web.json_response(json.loads((Path(__file__).parent / "h3_runtime.json").read_text()))


NODE_CLASS_MAPPINGS = {}
