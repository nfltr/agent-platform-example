# Agent platform on nfltr (reference example)

A small web service that gives your teams "cloud agent sessions" on your own
machines: submit a task over HTTP (or let a webhook submit it), a Claude Code
agent runs it on one of your machines, and the result, the machine and the
cost come back to the service.

There is no model in the service. It drives an nfltr **hub** over MCP the way
any program calls an API: `spawn_agent`, `send_message`, `stop_agent`,
`list_agents`, `list_nodes`, `request_approval` and `wait_for_agents`. Claude
Code runs only in the agents, on machines you joined as nodes.

```
 users, CI, alerting                     your machines
        │ HTTPS + token                  (nfltr node join, per-machine policy)
        ▼                                        ▲
 ┌──────────────────────┐   MCP (stdio)   ┌──────┴──────┐
 │ this service         │ ──────────────► │ nfltr mcp   │ ── relay ──► node ─► agent (claude)
 │ tasks.db, audit.jsonl│ ◄────────────── │ --toolset   │  (nfltr.xyz      node ─► agent
 └──────────────────────┘  results, cost  │ hub, 1/team │   or your own)
                                          └─────────────┘
```

| File | What it is |
|---|---|
| `app.py` | HTTP API, bearer-token auth, SQLite task store, webhooks, audit log |
| `github.py` | GitHub webhook signature check, `/agent` comments and failed CI runs as tasks, results as PR comments |
| `hubclient.py` | One `nfltr mcp --toolset hub --hub-id <team hub>` per team, driven with the MCP Python SDK |
| `index.html` | The task page (no external scripts or styles) |
| `config.example.json` | Teams, their hub ids, users' token hashes, webhooks, budgets |
| `Dockerfile`, `docker-compose.yaml` | The service in a container |

## 1. Join your machines

On every machine that should run agents, install nfltr and Claude Code, then
join it. The machine's owner decides what agents there may do:

```bash
curl -fsSL https://nfltr.xyz/install.sh | sh
nfltr config add-api-key        # your nfltr key; prompts, never argv
export CLAUDE_CODE_OAUTH_TOKEN=...   # or ANTHROPIC_API_KEY: the agents' Claude login, from env only

# a build box for the payments team, agents may run commands and push to its repos
nfltr node join --name build-1 --max-agents 2 --harness claude-code --allow-all-tools \
  --labels team=payments --allow-repo 'github.com/acme/payments-*' \
  --serve-hubs platform-payments

# a production box: read-only by default, writes only with the owner's signed grant
nfltr node join --name prod-1 --max-agents 1 --harness claude-code --allow-all-tools \
  --labels team=payments,env=prod --serve-hubs platform-payments --require-pin \
  --tool-policy-file prod-policy.json --approval-public-key nfltr-approval-pub-v1:...
```

`--serve-hubs` keeps a machine to its team's hub; `--require-pin` takes only
tasks that name it; `--tool-policy-file` denies tool calls by pattern, and its
`unless_approved` rules lift only for a turn carrying the owner's grant.

## 2. Configure and run the service

```bash
cp config.example.json config.json
printf %s "$ALICE_TOKEN" | shasum -a 256    # put the hex into teams.payments.users.alice
```

Each team gets its own `hub_id`: its own durable inbox, agents and budget.
A team's `guidance_file` (relative to the config; `platform-guidance.md` is
an example: `agent/<topic>` branches, no `__pycache__`/`*.pyc` or other build
artefacts in commits) holds its house rules. The service passes it to the
team's hub (`--hub-guidance-file`) and appends it to every task prompt it
spawns, because no model drives this hub and the agents are the ones who must
follow the rules. `POST /approvals` returns that full `prompt`; the owner
signs exactly it.
Run it against nfltr.xyz (the key from `NFLTR_API_KEY` or the saved
`nfltr config add-api-key`):

```bash
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
export NFLTR_API_KEY=...         # or rely on the saved nfltr config
.venv/bin/uvicorn app:app --port 8080
# or: docker compose up -d --build
```

Your own relay instead (`nfltr relay serve`, beta): set `NFLTR_SERVER`,
`NFLTR_PROXY_URL` and `NFLTR_RELAY_CERT_SHA256` (or `nfltr config set-relay`
once), for the service and the nodes alike.

The service needs no Claude credentials; only the nodes do.

## 3. Use it

```bash
T="Authorization: Bearer $ALICE_TOKEN"
curl -s localhost:8080/machines -H "$T"
curl -s localhost:8080/tasks -H "$T" -H 'Content-Type: application/json' \
  -d '{"prompt":"Find why the payments-api tests are flaky and push a fix branch.",
       "repo":"https://github.com/acme/payments-api","ref":"main",
       "labels":{"team":"payments"},"constraints":{"mutates_workspace":true}}'
curl -s localhost:8080/tasks/<id> -H "$T"                 # status, machine, result, cost
curl -s localhost:8080/tasks/<id>/messages -H "$T" -H 'Content-Type: application/json' \
  -d '{"text":"Also add a regression test."}'            # steer, or a follow-up turn
curl -s -X POST localhost:8080/tasks/<id>/stop -H "$T"
```

Or open http://localhost:8080/, paste your token, and watch tasks finish.

| Endpoint | Does |
|---|---|
| `POST /tasks` | `{prompt, machine?, labels?, repo?, ref?, approval?, constraints?}` → `spawn_agent`; any other spawn constraint (`model`, `effort`, `timeout_ms`, `budget`, `output_validation`, ...) goes in `constraints` unchanged. A refused spawn returns 400 with the hub's reason |
| `GET /tasks`, `GET /tasks/{id}` | The team's tasks (`?scope=mine`: only the ones you started); a running one shows its live status, machine, progress or what it waits for. A turn the hub finished whose result and cost are not stored yet shows `storing`, so `completed` always comes with its answer and cost. An approval grant is never returned: `constraints.approval` reads `attached` |
| `GET /costs` | Per developer of your team: tasks, tokens and USD |
| `POST /tasks/{id}/messages` | `send_message`: steer a running agent or continue a finished one |
| `POST /tasks/{id}/stop` | `stop_agent` |
| `GET /machines` | `list_nodes`: machines, labels, free slots |
| `POST /approvals` | `{machine, prompt}` → `request_approval`: the digest and command the machine's owner runs |
| `POST /hooks/{team}/{name}` | A webhook (bearer secret from the config) becomes a task: the hook's prompt plus the event as data. `Idempotency-Key` deduplicates |
| `POST /github` | GitHub's webhook: `/agent` comments and failed CI runs (below) |

A task for a machine with no free slot waits (status `pending`, with the
hub's `waiting` fact) and starts when one frees.

### GitHub: `/agent` comments and failed CI runs

`POST /github` takes a repository's webhook (`github.py`):

- A comment on a pull request (or issue) starting with `/agent ` from a login
  in `github.logins` whose developer belongs to the repository's team becomes
  that developer's task: the rest of the comment plus the repository, PR
  number, title and head branch; it runs on the PR's head branch
  (`constraints.workspace`), so the node must allow-list the repository
  (`--allow-repo`). Other logins are ignored.
- A `workflow_run` that completed with `conclusion: failure` (or a failed
  `check_suite` from a CI app other than GitHub Actions, which already sends
  the `workflow_run`) becomes an investigation (`ci_prompt` plus the run's URL,
  logs URL, branch and commit), submitted as `hook:github`. For a GitHub
  Actions run, the service also reads the failed job's log with its own token
  and adds the failed step's tail as data: from the step's start to the last
  `##[error]` line, at most 6,000 characters, timestamps dropped and
  token-shaped strings masked (GitHub already masks the repository's secrets
  as `***`). The agent needs no GitHub token for it. The log download from
  GitHub's storage never carries the token. If the token cannot read Actions,
  the task says so and the agent investigates without the log.
- When the task finishes, its result is posted on the PR as a comment: state,
  machine, cost, who started it, the answer (in a code block: agent output is
  untrusted, so it cannot mention people or render links), the branch, and a
  link to the task on this page (`github.public_url`). A spawn the hub refuses
  is answered on the PR with the hub's reason.

Set it up per repository (GitHub → Settings → Webhooks): payload URL
`https://<this service>/github`, content type `application/json`, a random
secret, events "Issue comments" and "Workflow runs". Create a fine-grained
personal access token for the repository with only **Issues: write**,
**Pull requests: write** and **Actions: read** (the service reads the PR and
a failed run's log and posts comments; it never pushes). Give both to the service from the environment
(`GITHUB_WEBHOOK_SECRET`, `GITHUB_TOKEN`) or from files named in the config
(`webhook_secret_file`, `token_file`, mode 0600); they never go on argv or into
logs.

**Build nodes push with their own credential.** The comment token above never
pushes. For a private repository, each build node needs its own push
credential, and it must be **https**. The node gives its agents a git
credential helper that answers only for repositories its `--allow-repo`
admits, by asking the node user's own git helpers; it does not scope SSH
keys. So:

- Make a fine-grained personal access token (or a GitHub App installation
  token) for only that repository, with **Contents: read and write** and
  nothing else, and a short expiry.
- Store it with git's own helper, as the node's OS user, without putting it
  on any process's argv:

  ```bash
  git config --global credential.helper store      # or osxkeychain / libsecret
  read -rs TOKEN                                     # paste the token; no echo, no history
  printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "$TOKEN" | git credential approve
  unset TOKEN
  ```

  `printf` is a shell builtin, so the token is in no process's argv.
  `store` writes `~/.git-credentials` with mode 0600.
- Use https repository URLs in `--allow-repo` and in the tasks' `repo`
  (`https://github.com/acme/payments-api`). The node's agents run as its OS
  user and can read that user's credential store. Scope the token to the one
  repository, run the node as a dedicated user, and revoke the token when
  the node leaves.

A delivery is refused when it is unsigned or the signature
(`X-Hub-Signature-256`) does not match (401), when the event's own timestamp
is older than `max_age_seconds` (400), when its `X-GitHub-Delivery` id or the
signed event id (comment id, run id and attempt) was seen before (409), and
over `max_tasks_per_minute` (429). A result whose comment could not be posted
is retried on the next completion and on restart.

### Risky actions: the owner signs

For a task that must change production on `prod-1`:

1. `POST /approvals {"machine":"prod-1","prompt":"<exact prompt>"}` returns
   `prompt_sha256`, the owner's command and `prompt`: the exact text the
   agent will get (your prompt plus the team's house rules).
2. The owner saves that `prompt`, reads it, and signs on their own machine:
   `nfltr orch hub approve --key-file ~/.config/nfltr/approval.key --node prod-1 --prompt-file fix.txt --ttl 15m --expect-digest <prompt_sha256>`.
3. `POST /tasks {"prompt":"<same prompt>","machine":"prod-1","approval":"nfltr-approval-v1...."}`.
   The node checks the signature, prompt, node and expiry; the service and
   the hub cannot forge it. The grant approves one task: the node spends it
   on the first turn that starts with it and refuses it to any later one,
   also after the node restarts. The service passes it to the hub once and
   never stores, logs or returns it, so no team member can read it back
   (`GET /tasks` shows `"approval": "attached"`).

## Team presets (`presets/`)

The same machines serve developers' own Claude Code sessions too. Check
these into your repositories and the admin's tooling:

| File | For | What it does |
|---|---|---|
| `.mcp.json` | developers (repo root) | Gives Claude Code the hub tools on nfltr.xyz: `nfltr mcp --toolset hub --hub-id dev-${USER}.payments-api --hub-guidance-file .nfltr/guidance.md`. The key comes from the developer's own `nfltr config add-api-key`, never the file |
| `guidance.md` | developers (as `.nfltr/guidance.md`) | The organisation's machines, what each is for and the house rules, carried verbatim to the hub model (at most 4 KiB) |
| `join-node.sh` | the admin, on each machine | `TEAM=payments NAME=build-1 ./join-node.sh` (or `KIND=prod APPROVAL_KEY=...`): one way to join every machine, with team labels, `--allow-repo`, `--serve-hubs platform-<team>,dev-*`, on staging `staging-policy.json`, and on prod `--require-pin`, `prod-policy.json` and the owner's approval key |
| `prod-policy.json` | the admin | Tool policy for prod: `kubectl` writes only with the owner's signed grant (`unless_approved`), never `git push` |
| `staging-policy.json` | the admin | Read-only tool policy for staging (`KIND=staging`): denies `kubectl` writes, service and container control, file/process/package changes, pushes and Claude's file-edit tools. It has no `unless_approved` rule, so it joins without `--approval-public-key` |

The rules match a command word wherever it starts: at the start, after a
separator, a quote, a backslash or a path. So `/usr/local/bin/kubectl`,
`env kubectl`, `sh -c "kubectl ..."`, `command kubectl`, `exec kubectl` and
`xargs kubectl` are denied too, as is `kubectl` spelled with quotes or
backslashes inside. A write verb anywhere later in the same command counts
(`kubectl -n x rollout ...`, `k=kubectl; $k delete ...`), so a read piped
into `grep delete` is denied as well: split such commands. A regex cannot
see everything: a script file, an interpreter (`python -c`), a shell
redirection (`>`) or an API call with `curl` can still write. The
credential each node holds, and the OS user it runs as, are the real
boundary (`docs/guides/orch-ops-incident.md`, Limits).

Hub ids: `dev-<login>.<project>` for a developer's own sessions (one per
project, since a second session on the same id fails closed on the hub's
lock), `platform-<team>` for this service's hubs. A team node joined with
`--serve-hubs platform-payments,dev-*` serves both; a trailing `*` is a
prefix. It keeps the account's hubs apart; it is not authentication (every
key of the account can name any hub id), so teams that must not trust each
other get separate accounts.

Each developer gets their own nfltr key (one key per person, named after
them: the dashboard shows it as **Started by** on every agent in Runs → By
hub, with the cost per key). Revoke a developer by deleting their key.

## What the service records

- `state/tasks.db`: per task the team, the developer who started it
  (`submitted_by`: the API token's user, the developer a GitHub login maps
  to, or `hook:<name>` for automation, `hook:github` for CI failures), source
  (api, webhook or github), prompt, constraints (an approval grant only as
  `attached`), status, turns, machine,
  answer, error, branch/sha, tokens and USD as the agents reported them.
- `state/audit.jsonl`: one line per submission, refusal, message, stop,
  completion, late result and GitHub event, each naming the `developer`
  (who, what, where it ran, cost).
- `state/nfltr/hub/`: the hubs' durable state. Keep it with `tasks.db`: on a
  restart the service reopens the same hub ids and receives every result it
  had not yet stored (it acknowledges each one after storing it; this needs
  an nfltr release with `wait_for_agents` `ack`, after v1.0.670).

## Not included (on purpose)

SSO, organisations and quotas beyond a per-team hub budget; per-task
containers; high availability (one service instance per hub id); a second
agent runtime. A real deployment adds them in front of or around this service.

## Requirements

- nfltr v1.0.673 or later on every machine (install: `curl -fsSL https://nfltr.xyz/install.sh | sh`).
  Earlier nodes accept an owner's approval grant more than once.
- Python 3.11+ for the service.

## Licence

This example is licensed under Apache-2.0 (see `LICENSE` where it is
published). nfltr itself is a separate product with its own terms.
