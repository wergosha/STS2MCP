"""Launch and protocol checks using a fake game API, never the real game."""

import asyncio
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def _entry_point() -> str:
    launcher = "sts2-mcp.exe" if os.name == "nt" else "sts2-mcp"
    path = Path(sys.executable).with_name(launcher)
    if path.is_file():
        return str(path)
    found = shutil.which("sts2-mcp")
    if found is None:
        raise AssertionError("Install the project first: uv sync --locked")
    return found


class _GameAPI(BaseHTTPRequestHandler):
    requests: list[tuple[str, str, dict]] = []

    def log_message(self, *args):
        pass

    def _respond(self, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        self.requests.append(("GET", url.path, query))
        self._respond({"state_type": "monster", "fixture": "Удар", "query": query})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(("POST", self.path, body))
        self._respond({"status": "ok", "received": body})


class LaunchTests(unittest.TestCase):
    def test_installed_entry_point_has_help(self):
        result = subprocess.run(
            [_entry_point(), "--help"], capture_output=True, text=True, timeout=15
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--no-trust-env", result.stdout)
        self.assertIn("--port", result.stdout)


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_handshake_and_http_passthrough(self):
        _GameAPI.requests = []
        api = ThreadingHTTPServer(("127.0.0.1", 0), _GameAPI)
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        try:
            # A broken inherited proxy must not intercept --no-trust-env calls.
            environment = {
                **os.environ,
                "HTTP_PROXY": "http://127.0.0.1:1",
                "HTTPS_PROXY": "http://127.0.0.1:1",
                "ALL_PROXY": "http://127.0.0.1:1",
                "NO_PROXY": "",
            }
            params = StdioServerParameters(
                command=_entry_point(),
                args=[
                    "--host", "127.0.0.1", "--port", str(api.server_port),
                    "--no-trust-env",
                ],
                env=environment,
            )
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    initialized = await asyncio.wait_for(session.initialize(), 15)
                    self.assertEqual(initialized.serverInfo.name, "sts2")
                    tools = await session.list_tools()
                    names = {tool.name for tool in tools.tools}
                    self.assertIn("get_game_state", names)
                    self.assertIn("combat_play_card", names)
                    self.assertIn("mp_get_game_state", names)

                    state = await session.call_tool("get_game_state", {"format": "json"})
                    self.assertFalse(state.isError)
                    self.assertEqual(json.loads(state.content[0].text)["fixture"], "Удар")
                    await session.call_tool(
                        "combat_play_card", {"card_index": 2, "target": "JAW_WORM_0"}
                    )
                    await session.call_tool("combat_play_card", {"card_index": 0})
                    await session.call_tool("mp_get_game_state", {"format": "markdown"})
                    await session.call_tool(
                        "search_wiki", {"query": "Удар", "item_type": "card", "limit": 2}
                    )

            self.assertEqual(_GameAPI.requests, [
                ("GET", "/api/v1/singleplayer", {"format": ["json"]}),
                ("POST", "/api/v1/singleplayer", {
                    "action": "play_card", "card_index": 2, "target": "JAW_WORM_0"
                }),
                ("POST", "/api/v1/singleplayer", {"action": "play_card", "card_index": 0}),
                ("GET", "/api/v1/multiplayer", {"format": ["markdown"]}),
                ("GET", "/api/v1/wiki", {"query": ["Удар"], "item_type": ["card"], "limit": ["2"]}),
            ])
        finally:
            await asyncio.to_thread(api.shutdown)
            api.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
