# Strata on Coolify

Runs [Strata](https://github.com/Niko1221/Strata) 0.2.10 (Qwen3.8-Flash-Next,
the full model at `IQ2_XS`) on an AMD RX 7900 XT (`gfx1100`) as a Coolify
Docker Compose resource, sharing the card with Jellyfin.

The image is assembled from the v0.2.10 Terminal source and the signed 0.1.56
HIP engine package (`strata-engine-0.1.56-linux-x86_64-hip-rx7900`), because
upstream has not published a `0.2.10-rocm-gfx110x` container tag yet. The
engine package is pinned by SHA-256 and verified by upstream's packager before
it enters the image; the source tree is pinned to the v0.2.10 commit. Nothing
is compiled, so a deploy takes minutes rather than the old 10–20 minute
`build_engine_hip()` run.

| Setting | Value | Why |
| --- | --- | --- |
| `FAMILY` / `MODEL` | `qwen` / `IQ2_XS` | all 512 experts at 2-bit, 35.5 GB of experts, 69 GB download |
| `CONTEXT` / `KV` | `131072` / `k8v4` | 128K, the context window the agent clients are configured for; KV streamed to RAM (~1.4 GB) |
| `PARALLEL` | `2` | two request slots, so a subagent can decode beside its parent instead of waiting for the whole answer |
| `STRATA_SET` | `--vram-reserve-mib=3072 --batch-mtp=1` | VRAM left for Jellyfin's VAAPI transcodes; MTP drafts in both slots |
| `VISION` / `TUNE` | `off` / `skip` | the Coder is used for text and tools only |

0.2.10 chooses the low-RAM mode itself. For IQ2_XS the engine maps the 33 GiB
expert arena through the file cache and the OS keeps the hot pages there; that
is what makes a 13K-token prompt finish in seconds instead of the old resident
mode's minute. It no longer needs the old `LOW_RAM`, `LAZY_LOAD`,
`IDLE_UNLOAD_S` or `KV_STREAMING` variables; those names are ignored with a
warning by the 0.2.x entrypoint. The Jellyfin-friendly idle unload and the
agent sampling defaults are applied once to the installed config by
[scripts/tune-strata.sh](scripts/tune-strata.sh) (see below), so they survive
container restarts and image updates.

## Why this helps subagents

The previous deployment served **one request at a time** and kept only the
live conversation. An agent that delegated to two helpers made the helpers
queue, and every helper turn re-read its whole prompt. 0.2.10 changes both
sides of that:

- `PARALLEL=2` gives the engine two batch slots. The second request is admitted
  while the first is decoding; `/v1/status` reports
  `"concurrency": {"serving": 2, "requested": 2}`. More than two requests still
  wait for a slot, so a large fan-out is bounded by the card.
- The conversation cache is on by default in 0.2.10 when the RAM left after
  the model loads allows it. A conversation that gives up the model to a
  sibling is parked and restored instead of read from token 0. The engine log
  says which budget it took; `/metrics` exposes `conversation_cache`. On this
  48 GB host the budget is 0 (see “Measured” below); the slots still keep the
  active sessions.
- A system prompt that starts every helper is checkpointed once, so helpers
  that share it start after it rather than re-reading it.
- 0.2.10 reads tool calls more robustly (`tool_call_recovery` is on), closes
  thinking that would otherwise leave no room for an answer, and the installer
  and engine have the agent-loop fixes made since 0.1.44.1.

Two slots, not more: every slot takes a session out of the expert cache, and
this 20 GB card has little room beside the 3 GB Jellyfin reserve. Two keeps the
single-request speed reasonable while removing the hard serialization; three
would trade more single-stream speed for a fan-out this card cannot keep busy.
`--batch-mtp=1` gives each slot the MTP drafter, which is what keeps the two
streams close to one stream's total speed. The exact numbers are measured
below.

**DSH:** the limit is **Plugins → Subagent → Subagent parallelism limit** in
the sidebar (not Settings); the Host default is 8. The separate `strata`
profile sets it to 2 and defaults to this model. The `web` profile still uses 8
and queues helpers past the second one at Strata's two slots. Two in flight is
the useful shape here; a wider fan-out is not.

## Deploying in Coolify

1. **New Resource → Docker Compose** from `siddiqua1/strata-coolify`.
   Set **Docker Compose Location** to `/docker-compose.yml` (Coolify's default
   is `/docker-compose.yaml`, and this repo's file is `.yml`).
2. **Environment Variables**: at minimum `API_KEY` (long random value, marked
   as a secret). Optional overrides: `STRATA_DATA_PATH` (default
   `/home/ash/strata`), `VIDEO_GID` (985), `RENDER_GID` (989), `FAMILY`,
   `MODEL`, `CONTEXT`, `KV`, `PARALLEL`, `VISION`, `TUNE`, `STRATA_SET`,
   `STRATA_VERSION`, `ENGINE_SHA256`.
   Remove the old `LOW_RAM`, `LAZY_LOAD`, `IDLE_UNLOAD_S`, `VRAM_RESERVE_MIB`,
   `KV_STREAMING`, `ROCM_TAG` and `STRATA_REF` variables if they were added in
   Coolify; 0.2.x does not read them.
3. **Domains**: add `http://strata.example.com` to service `strata`, port
   `8080`. Coolify generates the Traefik router, service and container labels
   from that domain and attaches the service to its own network, to which it
   also connects `coolify-proxy`. The compose file carries no Traefik labels or
   networks.
4. **Deploy.** The build downloads the pinned source (~32 MB), the engine
   package (~286 MB) and the Terminal's Python; no engine compile. On the first
   start the 0.2.x entrypoint moves the old `/data/models`, `/data/packs` and
   `/data/mtp` into `/data/Strata-data` with a rename inside the volume — no
   copy, no model download. It verifies the model files, downloads the 1.2 GB
   DFlash2 drafter once (the MTP is used because two slots are configured),
   writes the installed config and starts.
5. **Tune the server config once** after the first start (see below) and
   restart. This is what sets the sampling defaults, the thinking cap, the idle
   unload and `lazy_load`.

`strata.example.com` already resolves to the Cloudflare tunnel
(`*.example.com` → `http://localhost:80` → Traefik). Cloudflare terminates
TLS, so Traefik only needs the `http` entrypoint.

**There is deliberately no `ipAllowList`.** Tunnel traffic reaches Traefik from
localhost, not from LAN addresses, so a LAN allowlist would block every request.
Access control is the API key; add a Cloudflare Access policy if you want a
second gate.

**LAN access** without going through Cloudflare: point
`strata.example.com` at `192.168.1.10` in the LAN DNS or `/etc/hosts`,
and use `http://` (port 80). The same router serves both paths. That path is
plain HTTP, so the bearer key crosses the LAN unencrypted; use the Cloudflare
route on networks you do not control.

## Post-deploy config (sampling, thinking, idle unload)

`strata launch` rebuilds its private run config from the **installed** config on
every start. `POST /config` edits the private copy, so it is not enough for this
Docker deployment. Run the included script inside the container after the first
start, then restart:

```sh
C=$(docker ps -qf name=strata | head -1)
docker exec -i "$C" /bin/sh -s < scripts/tune-strata.sh
docker restart "$C"
```

It writes these keys to `/data/install/strata-<model>.json` (keeping a
`.before-tune` backup) and prints the path:

| Key | Value | Effect |
| --- | --- | --- |
| `sampling.temperature` | `0.3` | sampled instead of greedy |
| `sampling.top_p` / `top_k` / `min_p` | `0.95` / `40` / `0.02` | keeps code tokens plausible |
| `sampling.repetition_penalty` / `penalty_last_n` | `1.03` / `256` | mild, over a long window |
| `reasoning_budget_tokens` | `4096` | closes the thinking and leaves room for the answer/tool call |
| `reasoning_loop_recovery` | `recover` | interrupts reasoning that repeats whole passages |
| `reasoning_close_retry` | `true` | retries once when a reply ended inside thinking with no answer |
| `anthropic_thinking` | `on_request` | Claude Code's helper calls that ask for no thinking do not get any |
| `env_to_user` | `true` | moves OpenCode's `<env>` block to the first user turn, so helpers share a prompt prefix |
| `idle_unload_s` | `1800` | unloads after 30 idle minutes; the next request loads again |
| `lazy_load` | `true` | a container start does not load 34 GiB until a request needs it |
| `parallel` | `2` | fallback if the `PARALLEL` environment variable is removed |

A request's own `temperature`/`top_p`/.../`reasoning_budget_tokens` still wins.
The thinking budget and loop recovery are server defaults. Setup keeps keys it
does not manage on a reinstall, so the tuning survives.

## Using it

Clients need the API key and a request timeout of at least 600 s (a 200K prompt
is read at 2–3 min cold on this card class; 128K is shorter). Warm the model
before a session:

```sh
curl -X POST -H "Authorization: Bearer $STRATA_KEY" \
     -H "Content-Type: application/json" -d '{}' \
     https://strata.example.com/v1/load
```

- OpenAI-compatible: `https://strata.example.com/v1`
- Anthropic-compatible: `https://strata.example.com/v1/messages`
  (Claude Code: `ANTHROPIC_BASE_URL=https://strata.example.com`)
- Health: `GET /health` (200 whether or not the model is loaded)
- Status: `GET /v1/status` with the key; `concurrency.serving` is the number of
  request slots the engine accepted.

Point agent clients at model name `qwen3.8-flash-next-iq3_xxs`, context
`131072`, and an output cap of at least `8192` (the server also has
`answer_room`, but a client cap of `4096` leaves little room for a tool call).
Use a stable system prompt across a task's helper agents so their prompts share
the checkpointed prefix.

**Subagent limits.** Two requests decode at once; a third waits for a free
slot. Prompts are still admitted one at a time, and a long prompt makes a short
one wait (the engine's cooperative yield helps). On this card, the useful
pattern is two or three helpers with short, well-scoped prompts, not a wide
fan-out. The single model, the single GPU and the 40 GiB memory limit are the
bounds; the deployment does not turn the box into a parallel inference farm.

## Operating

- **Data** lives under `/data/Strata-data` in the volume (model files, pack,
  MTP layer) and `/data/{install,state,config,home}` (installed config,
  presets, tuning, API key, logs). The old `/data/{models,packs,mtp}` layout is
  moved on the first 0.2.x start; a rollback to the 0.1.x image needs those
  three folders moved back under `/data`.
- **Logs**: Coolify's log view, or `docker logs -f <container>`. The engine's
  own log is `/data/state/strata/launch/docker.engine.log` (and
  `/data/install` for setup).
- **Stop/start**: the entrypoint drains, unloads the model and releases the
  locked RAM on SIGTERM; `stop_grace_period` is 2 minutes. The image's
  healthcheck stays green while the model is idle-unloaded (it lists the model
  even when unloaded), so Traefik keeps the route.
- **Change model settings**: change `CONTEXT`, `KV`, `PARALLEL` or
  `STRATA_SET` in Coolify and redeploy/restart. The old `REINSTALL` variable is
  no longer read. A context or picture change makes setup write the installed
  config again; the tuning keys are preserved.
- **Upgrade Strata**: change `STRATA_VERSION` and the engine package SHA-256
  (or switch to the official image once the tag exists). A new engine may make
  an old tuning result less useful; re-run `scripts/tune-strata.sh` if the
  defaults change.
- **Memory**: `mem_limit: 40g` is a backstop above the measured footprint. The
  engine's own memory guard honours the cgroup limit and skips conversation
  parking when there is no room; it does not OOM the host by itself. Watch
  `docker stats` and host `free -h` after a real multi-agent session; Jellyfin
  and the host's page cache share the remaining RAM.

## Notes and known limits

- Upstream publishes container images from 0.2.1 on, but the newest published
  HIP tag at the time of writing is `0.2.9-rocm-gfx110x`; 0.2.10 is built from
  the release source and the signed engine package here. When
  `ghcr.io/niko1221/strata:0.2.10-rocm-gfx110x` appears, remove the `build:`
  block and use that `image:` instead.
- The 28.8 GB n-gram (PLE) table is read with `O_DIRECT`, bypassing page cache,
  so it does not count against `mem_limit`. It needs a fast NVMe.
- A cold 128K prompt has not been timed; a 13K-token prompt is measured at
  15.6 s in the measurements below. Longer prompts pay the same prompt rate plus their extra chunks.
- The image's Docker healthcheck probes `/v1/models` with the API key. During
  the first start (model preparation) the container is `starting`, not
  `unhealthy`; Traefik routes only once it is healthy.
- 2-bit IQ2_XS is not a reliable one-shot code generator. The measured repair
  loop (feed `rustc` errors back for one more round) is in
  [prompts/rust-lru-decorator.md](prompts/rust-lru-decorator.md); subagents that
  write code should be given the same retry budget.
- **Quant:** IQ2_XS was chosen over IQ3_XXS for speed. It reads a 13K prompt at
  ~880 tok/s and serves two concurrent tool turns in ~4 s each, where IQ3_XXS
  read the same prompt for minutes and tripped the engine watchdog. The cost is
  first-pass correctness: IQ2_XS measured 1 of 5 on the macro coding task
  against 2 of 10 for IQ3_XXS. The IQ3_XXS files are still on the volume, so
  rolling back is a one-variable change (and a load), not a download.

## Measured on this host (RX 7900 XT, Ryzen 9800X3D, 48 GB)

Measured on the 0.2.10 image, IQ2_XS, 128K context, two slots,
`--batch-mtp=1`.

- Image build: about 2–3 minutes with a warm Docker cache; a cold build also
  downloads the 32 MB source, 286 MB engine package, Terminal Python and
  wheels. No compile.
- Model install: the 68 GB IQ2_XS download, file check, one-time pack and MTP
  preparation took about 13 minutes on this connection, then a 15.7 s load.
  The old IQ3_XXS files were kept.
- Long prompt: 13,265 tokens read in 15.6 s (880 tok/s), answered in 15.6 s
  total. The same shape of prompt stalled IQ3_XXS for minutes and tripped the
  engine watchdog, which is what produced the DSH "engine stopped while this
  request waited" error.
- Single request: 64–88 tok/s depending on the output length (64.1 over 123
  generated tokens; 87.9 over a 31-token answer on the public route).
- Two concurrent requests: 56–70 tok/s aggregate over 5–6 s (for example 159
  and 197 tokens in 6.3 s); the two slots keep the total close to one stream.
- Two concurrent calculator tool calls: both returned `tool_calls` in 3.9 and
  4.3 s.
- Four concurrent 13K-token prompts (the DSH fan-out shape): all four
  completed in 51.8 s wall time; the engine stayed up, and prompt reads ran at
  772–880 tok/s. This is the case that previously killed IQ3_XXS and failed
  the queued DSH requests.
- Memory: 34.4 GiB in Docker against the 40 GiB limit; the engine maps
  33.0 GiB of experts through the file cache, and 17.5 GiB of 20.4 GiB VRAM is
  used, so the 3072 MiB reserve for Jellyfin is honoured. Host
  `MemAvailable` is about 2 GiB while the model is loaded; this is still a
  tight host, so keep Jellyfin's load in mind.
- Restart with the model unloaded (`lazy_load`): the container is healthy in
  about 18 s; `/v1/load` takes 15.7 s.
- Conversation cache: **off** on this host. After the model is loaded there is
  not enough free RAM to park conversations (`/metrics` shows
  `"enabled": false, "budget_mib": 0`). The two batch slots keep their active
  sessions, which covers a two-helper DSH tree; alternating chats beyond that
  re-read their prompts.
