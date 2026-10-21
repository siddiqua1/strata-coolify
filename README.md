# Strata on Coolify

Runs [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next **Coder**,
`IQ1_M`) on an AMD RX 7900 XT (`gfx1100`) as a Coolify Docker Compose resource,
sharing the card with Jellyfin.

Pinned to Strata `296b59d2f73c8f04a805df29c2fa97655adace78` (v0.1.44.1) and to
`rocm/dev-ubuntu-24.04:7.2.4-complete`, which matches the host's ROCm 7.2.4.
The HIP engine is compiled at image build time by `setup.py`'s own
`build_engine_hip()`, so container starts never compile.

| Setting | Value | Why |
| --- | --- | --- |
| `FAMILY` / `MODEL` | `coder` / `IQ1_M` | 23.4 GB of experts, 58.4 GB download |
| `CONTEXT` / `KV` | `204800` / `k8v4` | 200K, inside the trained 262144 (no rope scaling); KV streamed to RAM (~2.2 GB) |
| `LOW_RAM` | `off` | all experts resident in RAM (48 GB host) |
| `LAZY_LOAD` / `IDLE_UNLOAD_S` | `true` / `1800` | API answers at boot; model unloads after 30 idle minutes |
| `VRAM_RESERVE_MIB` | `3072` | VRAM left for Jellyfin's VAAPI transcodes |

## Deploying in Coolify

1. **New Resource → Docker Compose** from `siddiqua1/strata-coolify`.
   Set **Docker Compose Location** to `/docker-compose.yml` (Coolify's default
   is `/docker-compose.yaml`, and this repo's file is `.yml`).
2. **Environment Variables**: at minimum `API_KEY` (long random value, marked
   as a secret). Optional overrides: `STRATA_DATA_PATH` (default
   `/home/ash/strata`), `VIDEO_GID` (985), `RENDER_GID` (989), `FAMILY`,
   `MODEL`, `CONTEXT`, `KV`, `KV_STREAMING`, `IDLE_UNLOAD_S`, `LAZY_LOAD`,
   `VRAM_RESERVE_MIB`, `ROCM_TAG`, `STRATA_REF`.
3. **Domains**: add `http://strata.ash-siddiqui.com` to service `strata`, port
   `8080`. Coolify generates the Traefik router, service and container labels
   from that domain and attaches the service to its own network, to which it
   also connects `coolify-proxy`. The compose file carries no Traefik labels or
   networks.
4. **Deploy.** The first build compiles the engine (10–20 min); the first start
   downloads ~58 GB and then serves.

`strata.ash-siddiqui.com` already resolves to the Cloudflare tunnel
(`*.ash-siddiqui.com` → `http://localhost:80` → Traefik). Cloudflare terminates
TLS, so Traefik only needs the `http` entrypoint.

**There is deliberately no `ipAllowList`.** Tunnel traffic reaches Traefik from
localhost, not from LAN addresses, so a LAN allowlist would block every request.
Access control is the API key; add a Cloudflare Access policy if you want a
second gate.

**LAN access** without going through Cloudflare: point
`strata.ash-siddiqui.com` at `192.168.50.210` in the LAN DNS or `/etc/hosts`,
and use `http://` (port 80). The same router serves both paths.

## Using it

Clients need the API key and a request timeout of at least 600 s (a 200K prompt
is read at 2–3 min cold on this card class). Warm the model before a session:

```sh
curl -X POST -H "Authorization: Bearer $STRATA_KEY" \
     -H "Content-Type: application/json" -d '{}' \
     https://strata.ash-siddiqui.com/v1/load
```

- OpenAI-compatible: `https://strata.ash-siddiqui.com/v1`
- Anthropic-compatible: `https://strata.ash-siddiqui.com/v1/messages`
  (Claude Code: `ANTHROPIC_BASE_URL=https://strata.ash-siddiqui.com`)
- Health: `GET /health` (200 whether or not the model is loaded)

## Operating

- **Data** lives in `STRATA_DATA_PATH` on the host (`/home/ash/strata`): model
  files, MTP layer, config. ~70 GB. Backing it up is optional; a rebuild
  re-downloads.
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
- The first build pulls ~7.4 GB and leaves ~25 GB of image; model + image need
  roughly 100 GB, hence the NVMe data directory.
- Unverified, as with any new build: no published Coder throughput for the 7900
  XT (nearest: RX 9070 XT ~44 tok/s), and a cold 200K prompt is estimated at
  2–3 min. If ROCm reports permission errors on `/dev/kfd`, add
  `security_opt: [seccomp=unconfined]` to the service.
