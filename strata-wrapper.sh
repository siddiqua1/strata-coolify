#!/bin/sh
# Runs before upstream's docker-entrypoint.sh and keeps the settings that
# entrypoint does not expose as env vars in the model's config:
#   IDLE_UNLOAD_S     -> "idle_unload_s"  (unload after N idle seconds; 0 = never)
#   LAZY_LOAD         -> "lazy_load"      (start the API with the model unloaded)
#   VRAM_RESERVE_MIB  -> "--vram-reserve-mib" in "args" (VRAM left for Jellyfin)
#   API_KEY           -> "api_key"
#
# The config is patched on every start, so a changed env var in Coolify takes
# effect on the next restart. setup.py rewrites the config on a reinstall and
# drops hand-added "args"; patching here means nothing is lost when it does.
set -eu
cd /opt/strata

STRATA_DATA="${STRATA_DATA:-/data}"
FAMILY="${FAMILY:-coder}"
MODEL="${MODEL:-IQ1_M}"
CONTEXT="${CONTEXT:-204800}"
KV="${KV:-k8v4}"
KV_STREAMING="${KV_STREAMING:-on}"
LOW_RAM="${LOW_RAM:-off}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
IDLE_UNLOAD_S="${IDLE_UNLOAD_S:-1800}"
LAZY_LOAD="${LAZY_LOAD:-true}"
VRAM_RESERVE_MIB="${VRAM_RESERVE_MIB:-3072}"
API_KEY="${API_KEY:-}"

die() { echo "strata-wrapper: $*" >&2; exit 1; }

# The server listens on 0.0.0.0 behind Traefik; without a key anyone who can
# reach it can use it.
[ -n "$API_KEY" ] || die "API_KEY is empty; set it as a secret in Coolify"
case "$IDLE_UNLOAD_S" in ''|*[!0-9]*) die "IDLE_UNLOAD_S must be a whole number of seconds" ;; esac
case "$VRAM_RESERVE_MIB" in ''|*[!0-9]*) die "VRAM_RESERVE_MIB must be a whole number of MiB" ;; esac
case "$LAZY_LOAD" in true|false) ;; *) die "LAZY_LOAD must be true or false" ;; esac
case "$KV" in int8|q4_0|k8v4) ;; *) die "KV must be int8, q4_0 or k8v4" ;; esac
case "$KV_STREAMING" in auto|on|off) ;; *) die "KV_STREAMING must be auto, on or off" ;; esac

# Same naming as docker-entrypoint.sh: the qwen family has no prefix.
case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
tag="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
mkdir -p "$STRATA_DATA/config"

# First start (or REINSTALL=1): run setup here rather than in the upstream
# entrypoint, so the config can be patched before the server reads it. The
# flags mirror docker-entrypoint.sh's setup pass.
if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  echo "strata-wrapper: setting up $tag (downloads ~58 GB on the first run)"
  .venv/bin/python setup.py --setup --yes --backend hip --no-browser \
    --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision no \
    --data-dir "$STRATA_DATA" --host "$HOST" --api-key "$API_KEY" --port "$PORT" \
    --no-start --low-ram "$LOW_RAM" --kv "$KV" --kv-streaming "$KV_STREAMING" \
    --vram-reserve-mib "$VRAM_RESERVE_MIB"
  if [ -f "/opt/strata/strata-$tag.json" ] && [ ! -L "/opt/strata/strata-$tag.json" ]; then
    cp -f "/opt/strata/strata-$tag.json" "$cfg"
  fi
  [ -f "$cfg" ] || die "setup finished without writing $cfg"
fi

tmp="$cfg.tmp.$$"
jq --argjson idle "$IDLE_UNLOAD_S" \
   --argjson lazy "$LAZY_LOAD" \
   --arg vram "$VRAM_RESERVE_MIB" \
   --arg key "$API_KEY" '
  .idle_unload_s = $idle
  | .lazy_load = $lazy
  | .api_key = $key
  | .args = ((.args // []) as $a
      | [range(0; $a | length) as $i
         | select($a[$i] != "--vram-reserve-mib"
                  and ($i == 0 or $a[$i - 1] != "--vram-reserve-mib"))
         | $a[$i]]
      + ["--vram-reserve-mib", $vram])
' "$cfg" > "$tmp" || { rm -f "$tmp"; die "could not patch $cfg"; }
mv -f "$tmp" "$cfg"
echo "strata-wrapper: idle_unload_s=$IDLE_UNLOAD_S lazy_load=$LAZY_LOAD vram_reserve_mib=$VRAM_RESERVE_MIB"

# Setup is done, so the upstream entrypoint links the patched config and starts
# the server without a second setup pass.
export STRATA_DATA FAMILY MODEL PORT HOST API_KEY
export REINSTALL=0
exec ./docker-entrypoint.sh
