"""Small HTTP client shared by the operator commands."""
import json
import os
import shutil
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class RequestError(RuntimeError):
    def __init__(self, method, path, status, detail):
        self.status = status
        super().__init__(f"{method} {path}: {detail}")


class Client:
    def __init__(self, base, key, allow_local=False):
        url = urlsplit(base)
        if (not url.hostname or url.username or url.password or url.query or url.fragment
                or (url.scheme != "https" and not (allow_local and url.scheme == "http"
                    and url.hostname in ("localhost", "127.0.0.1", "::1")))):
            raise ValueError("Expected an HTTPS endpoint or an explicitly permitted loopback URL")
        self.base = base.rstrip("/")
        self.headers = {"Salad-Api-Key": key} if key else {}
        self.opener = build_opener(NoRedirect())

    def request(self, path, *, method="GET", body=None, content_type=None):
        headers = dict(self.headers)
        if content_type:
            headers["Content-Type"] = content_type
        try:
            request = Request(self.base + path, data=body, headers=headers, method=method)
            return self.opener.open(request, timeout=95)
        except HTTPError as err:
            err.close()
            raise RequestError(method, path, err.code, f"HTTP {err.code}") from None
        except (URLError, OSError) as err:
            raise RequestError(method, path, None, f"connection error ({type(err).__name__})") from None

    def json(self, path, payload=None, method=None):
        verb = method or ("POST" if payload is not None else "GET")
        with self.request(path, method=verb,
                          body=None if payload is None else json.dumps(payload).encode(),
                          content_type=None if payload is None else "application/json") as reply:
            return json.load(reply) if reply.status not in (202, 204) else None

    def download(self, path, output):
        output = Path(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        with NamedTemporaryFile(dir=output.parent, delete=False) as staging:
            temp = Path(staging.name)
            try:
                with self.request(path) as reply:
                    shutil.copyfileobj(reply, staging)
                    length = reply.headers.get("Content-Length")
                    if length is not None and staging.tell() != int(length):
                        raise RuntimeError("Incomplete download")
                staging.close()
                os.replace(temp, output)
            finally:
                temp.unlink(missing_ok=True)
