#!/usr/bin/env bash
# Join this machine as an agent node, the admin's way: one script for every
# machine of the organisation, so labels, scope and policy stay the same.
#
#   TEAM=payments NAME=build-1 ./join-node.sh [extra nfltr node join flags]
#   TEAM=payments NAME=prod-1 KIND=prod APPROVAL_KEY=nfltr-approval-pub-v1:... ./join-node.sh
#   GIT_NAME=payments-bot GIT_EMAIL=payments-bot@acme.example TEAM=payments NAME=build-1 ./join-node.sh
#
# Needs: nfltr (curl -fsSL https://nfltr.xyz/install.sh | sh), Claude Code,
# the node's nfltr key saved once (`nfltr config add-api-key`, prompts; never
# argv) and the agents' Claude login in the environment
# (CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY), never in this file.
set -euo pipefail

: "${TEAM:?TEAM=<team> (a label; developer hubs dev-<login>.<project>)}"
: "${NAME:?NAME=<machine id>}"
KIND="${KIND:-build}"          # build | staging | prod
SLOTS="${SLOTS:-2}"            # agents at once on this machine
REPOS="${REPOS:-github.com/acme/${TEAM}-*}"  # repositories agents may clone and push
HERE="$(cd "$(dirname "$0")" && pwd)"

# Who the agents' commits name: optional, the admin's choice (a team bot, the
# machine). Given to the node as git's own GIT_AUTHOR_*/GIT_COMMITTER_*, which
# it passes to its agents. Omitted: the node user's git config user.name and
# user.email if set, else no identity (the node invents none).
if [[ -n "${GIT_NAME:-}${GIT_EMAIL:-}" ]]; then
  : "${GIT_NAME:?GIT_NAME and GIT_EMAIL go together}" "${GIT_EMAIL:?GIT_NAME and GIT_EMAIL go together}"
  export GIT_AUTHOR_NAME="${GIT_NAME}" GIT_AUTHOR_EMAIL="${GIT_EMAIL}" GIT_COMMITTER_NAME="${GIT_NAME}" GIT_COMMITTER_EMAIL="${GIT_EMAIL}"
fi

# Which hubs this machine serves: the team's platform hub and every
# developer's own hub (a trailing * is a prefix). Scoping, not authentication.
args=(--name "${NAME}" --max-agents "${SLOTS}" --harness claude-code
  --labels "team=${TEAM},env=${KIND}" --allow-repo "${REPOS}"
  --serve-hubs "platform-${TEAM},dev-*")

case "${KIND}" in
  build)
    args+=(--allow-all-tools) ;;
  staging)
    # Agents look, they do not change: staging-policy.json denies writes
    # (no unless_approved rule, so no approval key). Drop it to let them change staging.
    args+=(--allow-all-tools --tool-policy-file "${HERE}/staging-policy.json") ;;
  prod)
    # Only spawns pinned to this machine; writes need the owner's signed grant.
    : "${APPROVAL_KEY:?APPROVAL_KEY=nfltr-approval-pub-v1:... printed by nfltr orch hub approval-key on the owner machine}"
    args=(--name "${NAME}" --max-agents 1 --harness claude-code --labels "team=${TEAM},env=prod"
      --serve-hubs "platform-${TEAM},dev-*" --require-pin --allow-all-tools
      --tool-policy-file "${HERE}/prod-policy.json" --approval-public-key "${APPROVAL_KEY}") ;;
  *)
    echo "KIND must be build, staging or prod" >&2; exit 2 ;;
esac

exec nfltr node join "${args[@]}" "$@"  # extra flags pass through (e.g. --workspace)
