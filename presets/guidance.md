Machines at Acme (joined by the platform admin; labels in brackets):

- build-1, build-2 [team=payments]: 16 cores, 64 GB, Go and Node toolchains,
  clones of github.com/acme/payments-*. Use them for builds, test suites and
  code changes; up to 2 agents each.
- gpu-1 [team=ml]: one GPU; only for ML jobs.
- prod-1 [team=payments, env=prod]: production read access. Takes only spawns
  pinned to it (constraints.machine "prod-1"); any write needs the owner's
  signed approval (request_approval). Look at staging-1 first.
- staging-1 [team=payments, env=staging]: read-only for agents (logs, service
  status, metrics); its tool policy denies changes.

Agents push branches named agent/<topic>; developers review and merge them.
Keep test runs to the packages a change touches unless asked for more.
