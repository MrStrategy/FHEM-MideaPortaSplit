from __future__ import annotations

import asyncio
import json
import logging
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Any
from urllib.parse import parse_qs, urlparse

from .state import StateStore

_LOGGER = logging.getLogger(__name__)


class BridgeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address, handler_class, *, loop, state_store, command_handler):
        super().__init__(server_address, handler_class)
        self.loop = loop
        self.state_store = state_store
        self.command_handler = command_handler


class Handler(BaseHTTPRequestHandler):
    server: BridgeHTTPServer

    def log_message(self, fmt: str, *args: Any) -> None:
        _LOGGER.info("HTTP %s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        body = self.rfile.read(length)
        data = json.loads(body.decode("utf-8"))
        if not isinstance(data, dict):
            raise ValueError("Request JSON must be an object")
        return data

    def _submit_command(self, command: dict[str, Any]) -> dict[str, Any]:
        future = asyncio.run_coroutine_threadsafe(
            self.server.command_handler(command),
            self.server.loop,
        )
        return future.result(timeout=60)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            state = self.server.state_store.get()
            ok = state.get("availability") == "online"
            self._send_json(
                HTTPStatus.OK if ok else HTTPStatus.SERVICE_UNAVAILABLE,
                {"ok": ok, "availability": state.get("availability"), "error": state.get("error")},
            )
            return

        if parsed.path == "/state":
            self._send_json(HTTPStatus.OK, self.server.state_store.get())
            return

        if parsed.path == "/set":
            query = parse_qs(parsed.query, keep_blank_values=False)
            command = {key: values[-1] for key, values in query.items()}
            try:
                self._send_json(HTTPStatus.OK, self._submit_command(command))
            except Exception as exc:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/set":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return

        try:
            command = self._read_json()
            self._send_json(HTTPStatus.OK, self._submit_command(command))
        except Exception as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})


class HTTPApi:
    def __init__(self, host: str, port: int, loop, state_store: StateStore, command_handler):
        self._server = BridgeHTTPServer(
            (host, port),
            Handler,
            loop=loop,
            state_store=state_store,
            command_handler=command_handler,
        )
        self._thread = Thread(target=self._server.serve_forever, daemon=True)

    def start(self) -> None:
        _LOGGER.info("Starting HTTP API on %s:%s.", *self._server.server_address)
        self._thread.start()

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)

