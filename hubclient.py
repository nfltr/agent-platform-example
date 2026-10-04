"""A team's nfltr hub, driven over MCP by this service: no LLM in the control path.

Each team gets one `nfltr mcp --toolset hub --hub-id <id>` child process. The
service calls the hub's tools directly (spawn_agent, send_message, stop_agent,
list_agents, list_nodes, request_approval) and one background task blocks on
wait_for_agents, acknowledging each finished turn once it is stored, so no
result is lost when this service restarts (it reopens the same hub id).
"""

import asyncio
import json
import logging
import os
import shlex
from contextlib import AsyncExitStack

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

log = logging.getLogger("hub")

# The hub frames text an agent wrote as untrusted content (it is meant for a
# model). It is untrusted for this service too: we store and show it as data.
OPEN, CLOSE = "<<<untrusted-content>>>\n", "\n<<<end-untrusted-content>>>"


def unframe(s):
    if isinstance(s, str) and s.startswith(OPEN) and s.endswith(CLOSE):
        return s[len(OPEN) : -len(CLOSE)]
    return s


class HubError(Exception):
    """The hub refused a tool call (an MCP isError result); str() is its reason."""


class Hub:
    def __init__(self, team, hub_id, state_dir, budget, on_completion, guidance_file=None):
        self.team, self.hub_id, self.guidance_file = team, hub_id, guidance_file
        self.state_dir, self.budget = state_dir, budget or {}
        self.on_completion = on_completion
        # Held while a spawn's row is written and while a completion is
        # stored, so a fast agent's completion never races its own row.
        self.lock = asyncio.Lock()
        # wait_for_agents returns at once when the hub has nothing pending;
        # spawn and send_message set this to wake the collector.
        self.work = asyncio.Event()
        self.dead = None

    def argv(self):
        args = ["mcp", "--toolset", "hub", "--hub-id", self.hub_id,
                "--task-store-file", os.path.join(self.state_dir, "nfltr", "tasks.json")]
        if "max_tokens" in self.budget:
            args += ["--hub-max-tokens", str(self.budget["max_tokens"])]
        if "max_usd" in self.budget:
            args += ["--hub-max-usd", str(self.budget["max_usd"])]
        if self.guidance_file:
            args += ["--hub-guidance-file", str(self.guidance_file)]
        # Connection flags for a private relay (e.g. --tls=false); the relay
        # address and API key come from NFLTR_SERVER / NFLTR_PROXY_URL /
        # NFLTR_API_KEY or the saved nfltr config, never argv.
        return args + shlex.split(os.environ.get("PLATFORM_NFLTR_ARGS", ""))

    async def start(self, stack: AsyncExitStack):
        os.makedirs(os.path.join(self.state_dir, "nfltr"), exist_ok=True)
        errlog = stack.enter_context(open(os.path.join(self.state_dir, f"hub-{self.team}.log"), "a"))
        params = StdioServerParameters(command=os.environ.get("NFLTR_BIN", "nfltr"), args=self.argv(),
                                       env=dict(os.environ))
        read, write = await stack.enter_async_context(stdio_client(params, errlog=errlog))
        self.session = await stack.enter_async_context(ClientSession(read, write))
        await self.session.initialize()
        self.collector = asyncio.create_task(self._collect())
        log.info("hub open team=%s hub_id=%s", self.team, self.hub_id)

    async def call(self, tool, args=None, timeout=120):
        r = await self.session.call_tool(tool, args or {}, read_timeout_seconds=timeout)
        text = r.content[0].text if r.content else ""
        if r.is_error:
            raise HubError(text)
        if tool in ("spawn_agent", "send_message"):
            self.work.set()
        return json.loads(text)

    async def _collect(self):
        # `ack` lists the seqs we have stored: the hub returns a completion
        # again (also after a restart) until a call acknowledges it, so a
        # result is never lost between the hub and our database.
        acked = []
        try:
            while True:
                self.work.clear()
                r = await self.call("wait_for_agents", {"timeout_ms": 600000, "ack": acked}, timeout=660)
                acked = []
                for c in r.get("completions", []):
                    for k in ("text", "error", "result", "partial_answer"):
                        c[k] = unframe(c.get(k))
                    async with self.lock:
                        self.on_completion(self.team, c)
                    acked.append(c["seq"])
                if not r.get("completions") and not r.get("pending"):
                    await self.work.wait()
        except Exception as e:  # the hub process went away: report it, /healthz turns 503
            self.dead = repr(e)
            log.exception("hub %s stopped delivering", self.hub_id)
