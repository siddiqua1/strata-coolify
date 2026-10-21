# Strata on Coolify

Runs [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, the full
model at `IQ2_XS`) on an AMD RX 7900 XT (`gfx1100`) as a Coolify Docker Compose
resource, sharing the card with Jellyfin.

Pinned to Strata `296b59d2f73c8f04a805df29c2fa97655adace78` (v0.1.44.1) and to
`rocm/dev-ubuntu-24.04:7.2.4-complete`, which matches the host's ROCm 7.2.4.
The HIP engine is compiled at image build time by `setup.py`'s own
`build_engine_hip()`, so container starts never compile.

| Setting | Value | Why |
| --- | --- | --- |
| `FAMILY` / `MODEL` | `qwen` / `IQ2_XS` | all 512 experts, 35.5 GB of experts, 68 GB download |
| `CONTEXT` / `KV` | `204800` / `k8v4` | 200K, inside the trained 262144 (no rope scaling); KV streamed to RAM (~2.2 GB) |
| `LOW_RAM` | `resident` | the experts the GPU does not hold are copied into RAM; 46 GB is not enough to lock all 35.5 GB |
| `LAZY_LOAD` / `IDLE_UNLOAD_S` | `true` / `1800` | API answers at boot; model unloads after 30 idle minutes |
| `VRAM_RESERVE_MIB` | `3072` | VRAM left for Jellyfin's VAAPI transcodes |

## Deploying in Coolify

1. **New Resource → Docker Compose** from `siddiqua1/strata-coolify`.
   Set **Docker Compose Location** to `/docker-compose.yml` (Coolify's default
   is `/docker-compose.yaml`, and this repo's file is `.yml`).
2. **Environment Variables**: at minimum `API_KEY` (long random value, marked
   as a secret). Optional overrides: `STRATA_DATA_PATH` (default
   `/home/ash/strata`), `VIDEO_GID` (985), `RENDER_GID` (989), `FAMILY`,
   `MODEL`, `LOW_RAM`, `CONTEXT`, `KV`, `KV_STREAMING`, `IDLE_UNLOAD_S`, `LAZY_LOAD`,
   `VRAM_RESERVE_MIB`, `SAMPLING_TEMPERATURE`, `SAMPLING_TOP_P`,
   `SAMPLING_TOP_K`, `SAMPLING_MIN_P`, `REPETITION_PENALTY`, `PENALTY_LAST_N`,
   `REASONING_BUDGET_TOKENS`, `REASONING_LOOP_RECOVERY`, `ROCM_TAG`,
   `STRATA_REF`.
3. **Domains**: add `http://strata.example.com` to service `strata`, port
   `8080`. Coolify generates the Traefik router, service and container labels
   from that domain and attaches the service to its own network, to which it
   also connects `coolify-proxy`. The compose file carries no Traefik labels or
   networks.
4. **Deploy.** The first build compiles the engine (10–20 min); the first start
   downloads ~58 GB and then serves.

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

## Using it

Clients need the API key and a request timeout of at least 600 s (a 200K prompt
is read at 2–3 min cold on this card class). Warm the model before a session:

```sh
curl -X POST -H "Authorization: Bearer $STRATA_KEY" \
     -H "Content-Type: application/json" -d '{}' \
     https://strata.example.com/v1/load
```

- OpenAI-compatible: `https://strata.example.com/v1`
- Anthropic-compatible: `https://strata.example.com/v1/messages`
  (Claude Code: `ANTHROPIC_BASE_URL=https://strata.example.com`)
- Health: `GET /health` (200 whether or not the model is loaded)

## Decoding defaults, and why

`setup.py` writes no `sampling` block, and a request that sends no temperature
then decodes **greedy**. On a low-bit model a hard prompt (macro-heavy Rust,
for example) falls into a loop inside its thinking: it spends the whole token
budget there and returns no answer at all. This was measured on the Coder
`IQ1_M` the box ran first, and the defaults are kept for `IQ2_XS`. `strata-wrapper.sh` therefore writes:

| Key | Value | Effect |
| --- | --- | --- |
| `sampling.temperature` | `0.3` | sampled instead of greedy |
| `sampling.top_p` / `top_k` / `min_p` | `0.95` / `40` / `0.02` | keeps code tokens plausible |
| `sampling.repetition_penalty` / `penalty_last_n` | `1.03` / `256` | mild, over a long window |
| `reasoning_budget_tokens` | `2048` | closes the thinking and starts the answer |
| `reasoning_loop_recovery` | `recover` | interrupts reasoning that repeats whole passages |

A request's own `temperature`/`top_p`/... still wins; the thinking budget and
loop recovery always apply. Change the defaults with the matching environment
variables (above) and restart.

**Quality ceiling:** IQ1_M writes correct code for straightforward tasks
(verified: merge two sorted `Vec<i32>`, reverse a string), but it cannot write
correct `macro_rules!` or proc-macro Rust and invents syntax like `macro!`.
That is the quant, not the settings; a bigger model is the only real fix.

## Operating

- **Data** lives at `/home/ash/strata` on the host (62 GB after the first
  start): model files, MTP layer, config. Backing it up is optional; a rebuild
  re-downloads. Coolify resolves the volume path when the resource's compose is
  saved, so to move it, edit the `volumes:` entry in the compose file (Coolify's
  Compose tab) and redeploy, not just the `STRATA_DATA_PATH` variable.
- **Change model settings** (context, KV, family/model): set `REINSTALL=1` in
  Coolify for one start, then remove it. `strata-wrapper.sh` re-runs setup and
  re-applies `idle_unload_s`, `lazy_load`, `api_key` and `--vram-reserve-mib`.
- **Upgrade Strata**: change `STRATA_REF` to a new commit and redeploy
  (a full engine rebuild). The image pin keeps upgrades deliberate.
- **Logs**: Coolify's log view, or `docker logs -f <container>`.
- **Stop/start**: the engine releases locked RAM on SIGTERM; `stop_grace_period`
  is 60 s. If Coolify's Stop uses SIGKILL, the kernel still frees the RAM.

## Notes and known limits

- `mem_limit: 32g` is a backstop, not a measured number. After a real coding
  session, compare `docker stats` and lower it to footprint + margin.
- The service disables the image's Docker healthcheck (`healthcheck: disable`).
  Traefik only routes containers that are healthy or have no healthcheck, and
  the first start spends about an hour downloading with nothing listening on
  :8080 yet. Use `GET /health` (200 as soon as the server is up, loaded or not)
  to know when it is ready.
- The model's 28.8 GB n-gram (PLE) table is read with `O_DIRECT`, bypassing page
  cache, so it does not count against `mem_limit`. It needs a fast NVMe: a
  spinning disk stalls prompts.
- The first build pulls ~7.4 GB and leaves a 22.4 GB image; model + image need
  roughly 100 GB, hence the NVMe data directory.
- Unverified: a cold 200K-token prompt has not been timed (estimated 2–3 min).
  If ROCm reports permission errors on `/dev/kfd`, add
  `security_opt: [seccomp=unconfined]` to the service.

## Measured on this host (RX 7900 XT, Ryzen 9800X3D, 48 GB)

- Image build: ~5 min including the 7.4 GB base pull; the HIP engine itself
  compiles in about a minute.
- First start: 58.4 GB download plus packing the MTP layer. The model is
  reusable across container recreations; later starts skip setup entirely.
- Model load: 23.42 GiB of experts at 3.3–3.7 GiB/s (12–15 s).
- Memory: 27 GiB RSS against the 32 GiB limit; 17.3 GiB of 20 GiB VRAM used, so
  the 3072 MiB reserve for Jellyfin is honoured.
- Decode: 47.7 tok/s over a 32-token answer with speculative decoding, expert
  cache 80.9% hit.
- Restart with the model unloaded: `/health` answers in about 3 s.
