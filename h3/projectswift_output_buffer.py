#!/usr/bin/env python3
"""Worker-side output spool; launched beside ComfyUI, never inside its core."""

import argparse
from contextlib import contextmanager
import hashlib
import http.client
import json
import logging
import os
from pathlib import Path
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CHUNK_BYTES = 8 * 1024 * 1024
PREFIX = "/internal/projectswift-output-buffer/deliveries"


def file_references(value):
    references = {}

    def collect(item):
        if isinstance(item, dict):
            if isinstance(item.get("filename"), str) and item.get("type") == "output":
                reference = {"filename": item["filename"], "subfolder": item.get("subfolder", ""), "type": "output"}
                references[(reference["subfolder"], reference["filename"])] = reference
            else:
                for child in item.values():
                    collect(child)
        elif isinstance(item, list):
            for child in item:
                collect(child)

    collect(value)
    return [references[key] for key in sorted(references)]


def output_path(root, reference):
    filename = reference["filename"]
    subfolder = reference["subfolder"]
    if not filename or "/" in filename or "\\" in filename or filename in (".", ".."):
        raise ValueError("invalid output filename")
    if subfolder and any(part in ("", ".", "..") or "\\" in part for part in subfolder.split("/")):
        raise ValueError("invalid output subfolder")
    candidate = (root / subfolder / filename).resolve()
    if not candidate.is_relative_to(root.resolve()) or not candidate.is_file():
        raise ValueError("output is missing or outside ComfyUI output root")
    return candidate


def sha256_file(file):
    digest = hashlib.sha256()
    with file.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def completed_at(history, observed_at):
    for message in history.get("status", {}).get("messages", []):
        if isinstance(message, list) and len(message) == 2 and message[0] == "execution_success":
            timestamp = message[1].get("timestamp")
            if isinstance(timestamp, (int, float)) and timestamp > 0:
                return min(observed_at, timestamp / 1000)
    return observed_at


class Spool:
    def __init__(self, database):
        self.database = database
        database.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS outputs (id TEXT PRIMARY KEY, completed REAL NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL)")
            connection.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.database, timeout=30)
        connection.execute("PRAGMA synchronous=FULL")
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def observe(self, history, client_id, now):
        with self.connect() as connection:
            for prompt_id, item in history.items():
                prompt = item.get("prompt", [])
                context = prompt[3].get("projectswift_output_delivery", {}) if len(prompt) > 3 and isinstance(prompt[3], dict) else {}
                status = item.get("status", {})
                if context.get("clientID") != client_id or not context.get("deliveryID") or not status.get("completed") or status.get("status_str") != "success":
                    continue
                references = file_references(item.get("outputs", {}))
                if not references:
                    continue
                timestamp = completed_at(item, now)
                # The queue graph and extra_data can contain application metadata;
                # delivery recovery only needs output/status information.
                saved_history = {prompt_id: {"outputs": item["outputs"], "status": status}}
                payload = {"version": 1, "clientID": client_id, "deliveryID": context["deliveryID"], "promptID": prompt_id,
                           "completedAt": timestamp, "history": saved_history, "references": references}
                connection.execute("INSERT OR IGNORE INTO outputs VALUES (?, ?, ?, 'pending')",
                                   (context["deliveryID"], timestamp, json.dumps(payload)))

    def outstanding(self):
        with self.connect() as connection:
            return [(row[0], row[1], json.loads(row[2]), row[3]) for row in connection.execute("SELECT id, completed, payload, state FROM outputs WHERE state != 'received' ORDER BY completed, id")]

    def mark(self, identifier, state):
        with self.connect() as connection:
            connection.execute("UPDATE outputs SET state = ? WHERE id = ?", (state, identifier))

    def spill_enabled(self, now, delay_seconds):
        rows = self.outstanding()
        with self.connect() as connection:
            saved = connection.execute("SELECT value FROM settings WHERE key = 'spilling'").fetchone()
            enabled = bool(rows) and (bool(saved and saved[0]) or now - rows[0][1] >= delay_seconds)
            connection.execute("INSERT OR REPLACE INTO settings VALUES ('spilling', ?)", (int(enabled),))
        return enabled


class Receiver:
    def __init__(self, base_url, token):
        url = urllib.parse.urlsplit(base_url)
        local_http = url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1")
        if (url.scheme != "https" and not local_http) or not url.netloc or url.username or url.password or url.path not in ("", "/") or url.query or url.fragment:
            raise ValueError("invalid output buffer URL")
        self.base_url = base_url.rstrip("/") + PREFIX
        self.token = token

    def request(self, identifier, suffix="", method="GET", body=None, offset=None):
        url = self.base_url + "/" + urllib.parse.quote(identifier, safe="") + suffix
        headers = {"Authorization": "Bearer " + self.token}
        if isinstance(body, dict):
            body = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if offset is not None:
            headers["X-Output-Buffer-Offset"] = str(offset)
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)

    def upload(self, payload, root):
        files = []
        for reference in payload["references"]:
            file = output_path(root, reference)
            files.append({"reference": reference, "bytes": file.stat().st_size, "sha256": sha256_file(file)})
        manifest = {key: value for key, value in payload.items() if key != "references"}
        manifest["files"] = files
        status = self.request(payload["deliveryID"], method="POST", body=manifest)
        if status["state"] in ("received", "ready"):
            return status["state"]
        for index, file in enumerate(files):
            offset = status["offsets"][index]
            with output_path(root, file["reference"]).open("rb") as handle:
                handle.seek(offset)
                while offset < file["bytes"]:
                    chunk = handle.read(min(CHUNK_BYTES, file["bytes"] - offset))
                    if not chunk:
                        raise ValueError("output changed during upload")
                    result = self.request(payload["deliveryID"], f"/files/{index}", "PUT", chunk, offset)
                    if result.get("state") == "received":
                        return "received"
                    offset = result["offset"]
        return self.request(payload["deliveryID"], "/commit", "POST", {})["state"]


def upload_pass(spool, receiver, root, delay_seconds, stop, now=None):
    for identifier, _, _, state in spool.outstanding():
        try:
            # Receipts also cover direct downloads, so GET /view alone is never
            # mistaken for a successful, durable delivery to the Mac.
            remote = receiver.request(identifier, "/status")["state"]
            if remote == "received":
                spool.mark(identifier, "received")
            elif state == "buffered" and remote != "ready":
                spool.mark(identifier, "pending")
        except (OSError, ValueError, http.client.HTTPException) as error:
            logging.warning("Output receipt retry: %s", type(error).__name__)
    if not spool.spill_enabled(time.time() if now is None else now, delay_seconds):
        return
    for identifier, _, payload, state in spool.outstanding():
        if stop.is_set():
            return
        if state == "pending":
            try:
                result = receiver.upload(payload, root)
                spool.mark(identifier, "received" if result == "received" else "buffered")
                logging.info("Output %s %s", identifier, result)
            except (OSError, ValueError, http.client.HTTPException) as error:
                logging.warning("Output upload retry: %s", type(error).__name__)


def run_uploader(spool, receiver, root, delay_seconds, stop):
    while not stop.wait(10):
        upload_pass(spool, receiver, root, delay_seconds, stop)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--comfy-url", default="http://127.0.0.1:8188")
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--state", default=Path("/opt/projectswift-output-buffer/spool.sqlite"), type=Path)
    args = parser.parse_args()
    base_url = os.environ.get("PROJECTSWIFT_OUTPUT_BUFFER_URL", "")
    token = os.environ.get("PROJECTSWIFT_OUTPUT_BUFFER_WRITER_TOKEN", "")
    client_id = os.environ.get("PROJECTSWIFT_OUTPUT_BUFFER_CLIENT_ID", "")
    if not base_url or not token or not client_id:
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    spool = Spool(args.state)
    receiver = Receiver(base_url, token)
    stop = threading.Event()
    uploader = threading.Thread(target=run_uploader, args=(spool, receiver, args.output_root, 180, stop), daemon=True)
    uploader.start()
    try:
        while not stop.is_set():
            try:
                with urllib.request.urlopen(args.comfy_url.rstrip("/") + "/history", timeout=30) as response:
                    spool.observe(json.load(response), client_id, time.time())
            except (OSError, ValueError, http.client.HTTPException) as error:
                logging.debug("ComfyUI history unavailable: %s", type(error).__name__)
            stop.wait(10)
    finally:
        stop.set()


if __name__ == "__main__":
    main()
