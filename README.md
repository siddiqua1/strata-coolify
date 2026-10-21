# Strata on Coolify

Runs [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, the full
model at `IQ3_XXS`) on an AMD RX 7900 XT (`gfx1100`) as a Coolify Docker Compose
resource, sharing the card with Jellyfin.

Pinned to Strata `296b59d2f73c8f04a805df29c2fa97655adace78` (v0.1.44.1) and to
`rocm/dev-ubuntu-24.04:7.2.4-complete`, which matches the host's ROCm 7.2.4.
The HIP engine is compiled at image build time by `setup.py`'s own
`build_engine_hip()`, so container starts never compile.

| Setting | Value | Why |
| --- | --- | --- |
| `FAMILY` / `MODEL` | `qwen` / `IQ3_XXS` | all 512 experts, 42.9 GB of experts, 76 GB download |
| `CONTEXT` / `KV` | `204800` / `k8v4` | 200K, inside the trained 262144 (no rope scaling); KV streamed to RAM (~2.2 GB) |
| `LOW_RAM` | `resident` | the experts the GPU does not hold are copied into RAM; 46 GB is not enough to lock all 42.9 GB |
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
`IQ1_M` the box ran first, and the defaults are kept for `IQ3_XXS`. `strata-wrapper.sh` therefore writes:

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

**Quality, measured:** on IQ3_XXS the simple code tasks compile (verified with
`rustc`: merging two sorted `Vec<i32>`, and the LRU struct itself). The
macro-in-one-file task compiles **2 times in 10** — the passing samples are a
real `macro_rules!` decorator over a `thread_local! RefCell<LruCache<K,V>>` with
tests. The failures are one-error slips (macro fragment rules, a borrow-checker
error, doc-comment placement). IQ2_XS, the 2-bit step below, compiled 1 in 5 on
the same prompt, so 3 bits buys idiom and speed, not reliability: treat this
task as retry-until-it-compiles, and 4-bit (~93% quant agreement) as the next
real step.

**Getting usable code out of it.** A one-line prompt compiled 1 time in 5 on
this model. A structured prompt (exact API, macro shape, examples, tests) kept
the same first-pass rate but made every sample structurally right — ownership
slips (`E0382` on `prev`/`key`) and macro-fragment errors were the only
failures. Feeding the `rustc` errors back for one more round took **5 of 5**
samples to compiling code with all four tests passing. The prompt and the
measured workflow are in
[prompts/rust-lru-decorator.md](prompts/rust-lru-decorator.md); an agent with
shell access can run that loop itself, in a plain chat you paste the compiler
output back.

## Operating

- **Data** lives at `/home/ash/strata` on the host (118 GB for IQ3_XXS after
  the first start: 76 GB download, ~41 GB expert pack, ~6 GB MTP: model files,
  MTP layer, config). Backing it up is optional; a rebuild re-downloads. Coolify resolves the volume path when the resource's compose is
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

- `mem_limit: 38g` is a backstop: the measured footprint is 34.1 GiB. After a
  real coding session, compare `docker stats` and tighten it to footprint + margin.
- The service disables the image's Docker healthcheck (`healthcheck: disable`).
  Traefik only routes containers that are healthy or have no healthcheck, and
  the first start spends about half an hour downloading with nothing listening on
  :8080 yet. Use `GET /health` (200 as soon as the server is up, loaded or not)
  to know when it is ready.
- The model's 28.8 GB n-gram (PLE) table is read with `O_DIRECT`, bypassing page
  cache, so it does not count against `mem_limit`. It needs a fast NVMe: a
  spinning disk stalls prompts.
- The first build pulls ~7.4 GB and leaves a 22.4 GB image; model, pack and
  image need roughly 145 GB, hence the NVMe data directory.
- Unverified: a cold 200K-token prompt has not been timed (estimated 2–3 min).
  If ROCm reports permission errors on `/dev/kfd`, add
  `security_opt: [seccomp=unconfined]` to the service.

## Measured on this host (RX 7900 XT, Ryzen 9800X3D, 48 GB)

- Image build: ~5 min including the 7.4 GB base pull; the HIP engine itself
  compiles in about a minute.
- First start: 76 GB download, ~41 GB expert pack and ~6 GB MTP layer (118 GB
  in the data directory). Reusable across container recreations; later starts
  skip setup entirely.
- Model load: 42.9 GB arena, the experts the GPU does not hold copied into RAM;
  ~15 s when the files are in page cache, longer after a cold boot.
- Memory: 34.1 GiB against the 38 GiB limit; 17.3 GiB of 20 GiB VRAM used, so
  the 3072 MiB reserve for Jellyfin is honoured.
- Decode: 69.3 tok/s over a 3,271-token answer with speculative decoding,
  expert cache 84.1% hit.
- Restart with the model unloaded: `/health` answers in about 2 s.
