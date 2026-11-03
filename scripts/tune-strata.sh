#!/bin/sh
# Apply the deployment's server-side defaults to the installed Strata config.
#
# Run this ONCE inside the Strata container after the first start has written
# /data/install/strata-<model>.json, then restart the container:
#
#   docker exec -i "$(docker ps -qf name=strata | head -1)" /bin/sh -s \
#     < scripts/tune-strata.sh
#   docker restart "$(docker ps -qf name=strata | head -1)"
#
# `strata launch` copies the installed config into its private run config on
# every start, so these values survive container restarts and image updates.
# Setup keeps keys it does not manage when it runs again, so a reinstall keeps
# them too. The private launch copy is written fresh each start; editing it with
# `POST /config` is not enough for this Docker deployment.
set -eu

PY=/opt/strata/terminal/python/bin/python3
[ -x "$PY" ] || PY=python3

found=0
for cfg in /data/install/strata-*.json; do
  [ -f "$cfg" ] || continue
  found=1
  cp -p "$cfg" "$cfg.before-tune"
  "$PY" - "$cfg" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)

# Tuned on IQ3_XXS for code/agent work: sampled decoding instead of greedy, a
# mild repetition penalty over a long window, and a thinking cap that leaves
# room for a tool call in a subagent turn. A request's own values still win.
cfg["sampling"] = {
    "temperature": 0.3,
    "top_p": 0.95,
    "top_k": 40,
    "min_p": 0.02,
    "repetition_penalty": 1.03,
    "penalty_last_n": 256,
}
cfg["reasoning_budget_tokens"] = 4096
cfg["reasoning_loop_recovery"] = "recover"
cfg["reasoning_close_retry"] = True
# Claude Code's helper calls ask for no thinking; honour that as Anthropic does.
cfg["anthropic_thinking"] = "on_request"
# OpenCode puts its <env> block in the system turn; move it to the first user
# turn so every subagent of one task shares the same prompt prefix.
cfg["env_to_user"] = True
# The box also runs Jellyfin: give the GPU back after 30 idle minutes and start
# lazily so a container start does not load 34 GiB until a request needs it.
cfg["idle_unload_s"] = 1800
cfg["lazy_load"] = True
# If the environment is removed later, the installed config still gives the
# entrypoint two request slots.
cfg.setdefault("parallel", 2)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=1, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"tuned {path}")
PYEOF
done

[ "$found" = 1 ] || {
  echo "no /data/install/strata-*.json yet: start the server once, then run this again" >&2
  exit 1
}
echo "restart the container to apply the tuning"
