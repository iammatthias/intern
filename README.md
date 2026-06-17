# intern

![Autonomous Intern](https://cdn.autonomous.ai/production/ecm/260605/intern(3).webp)

The [Autonomous Intern](https://www.autonomous.ai/ai-gadgets/intern) is an agentic Raspberry Pi in a fun little form factor.

This script turns a fresh Debian Trixie install into one: the **Hermes** agent (Nous Research) behind a **Caddy** web layer, **Tailscale** so you can reach it from anywhere, and an optional **Rabbit R1** channel. Memory is just Hermes' own built-in store — no external database to babysit.

It's one file, `setup`, and it does the whole thing. Re-run it whenever — it's idempotent. It also works out on its own whether to stand up a Wi-Fi onboarding portal or just use the connection you've already got.

## What it sets up

| Component | What it does |
|-----------|--------------|
| **Caddy** | Serves the setup web UI on `:80`, reverse-proxies `/api/*` → `intern-server:5000`, and a loopback `:9080` Host/Origin-rewrite hop for the dashboard |
| **intern backend** | The Autonomous `intern-server` (LED ring on SPI0, Wi-Fi onboarding API) |
| **Hermes agent** | Gateway as a systemd service (`hermes-gateway`), pinned to a release tag (default `v2026.6.5` = v0.16.0) |
| **Memory** | Hermes' built-in store — a ~2k `MEMORY.md` plus Skills / procedural memory it writes itself. No vector DB, no Docker (see [Memory](#memory)) |
| **Tailscale** | SSH over the tailnet (regular sshd, key auth); the Hermes dashboard published tailnet-only on standard HTTPS `:443` |
| **Hermes dashboard** | Web UI for config / API keys / chat (`hermes-dashboard`, loopback `:9119`) |
| **LED bridge** | Hermes lifecycle hooks → `intern-server`'s `/api/led` so the ring tracks what the agent's doing (idle / thinking / working) |
| **Gateway shim** | `intern-gateway-shim` answers the OpenClaw `:18789` WS handshake so `intern-server` stops reconnect-looping under Hermes |
| **Rabbit R1 channel** | Optional: the third-party [`r1_shim`][r1-shim] adapter on `:18790` + a pairing QR rendered into the dashboard as a tile |
| Base plumbing | locale, RPi-5 Wi-Fi stability, SPI enable (runtime + reboot), AP/STA Wi-Fi switching (hostapd/dnsmasq), OTA backend, firewall |

## Memory

Hermes brings its own memory, and it's deliberately simple: a ~2k-token `MEMORY.md` the agent keeps current, plus the Skills and procedural memory it writes for itself as it works. No vector database, no Docker stack, no embeddings to pay for.

This used to run [Honcho](https://github.com/plastic-labs/honcho) as a self-hosted memory backend, and it got ripped out — it was a fragile, RAM-hungry over-complication for what it actually bought us. The Hermes maintainers land in the same place: asked what memory system he runs, Teknium's answer was *"I use just the default memory!"* — the 2k memory file plus the procedural memory it creates on its own. So that's what this runs too.

## Requirements

- **Raspberry Pi 5** with Raspberry Pi OS **Trixie** (Debian 13), 64-bit, on an SD card.
- Internet during setup (Ethernet, a pre-baked Wi-Fi, or onboard via the captive portal).
- Run as **root**.
- An **OpenRouter** (or other OpenAI-compatible) API key for the LLM, and optionally a **Tailscale** auth key for unattended tailnet join.

## Usage

On a fresh Pi 5 (Trixie, with internet), as root:

```sh
OPENROUTER_API_KEY=sk-or-... \
TS_AUTHKEY=tskey-... \
  sudo -E bash setup
```

A desk/dev box you reach over Wi-Fi (keeps `wlan0` + SSH up, no AP switch, no firewall, no reboot):

```sh
SKIP_FIREWALL=1 SKIP_REBOOT=1 \
OPENROUTER_API_KEY=sk-or-... \
TS_AUTHKEY=tskey-... \
  sudo -E bash setup
```

### Key environment overrides

| Var | Purpose |
|-----|---------|
| `TS_AUTHKEY` / `TS_HOSTNAME` | Tailscale unattended join + tailnet hostname (default `intern-<serial>`) |
| `OPENROUTER_API_KEY` | LLM key for Hermes on the unpaired / bring-your-own path |
| `HERMES_MODEL` / `HERMES_FALLBACK_MODEL` | optional — pin a chat model; default **unset** (pick it in the dashboard) |
| `HERMES_BRANCH` | Hermes release tag (default `v2026.6.5`) |
| `R1_SHIM_ENABLED` / `R1_SHIM_TOKEN` / `R1_SHIM_PORT` | Rabbit R1 channel: on by default, token auto-generated (fixed), port `18790` |
| `R1_SHIM_REPO_RAW` | Source of the `r1_shim` adapter + Hermes patch ([iammatthias/r1-hermes-shim][r1-shim]) |
| `AP_MODE` | `auto` (default) / `force` / `skip` — captive-portal onboarding vs. use existing Wi-Fi |
| `SKIP_AP` / `SKIP_FIREWALL` / `SKIP_REBOOT` | desk/dev opt-outs |
| `WIFI_SSID` / `WIFI_PASS` | provision Wi-Fi up front so a flashed image comes up online |
| `INTERN_SKILLS_ZIP_URL` / `GITHUB_TOKEN` | onboarding-skill source (best-effort, non-fatal) |

## Reaching the dashboard

With Tailscale up, the script publishes the Hermes dashboard tailnet-only at `https://<your-tailnet-fqdn>/` (standard port 443) and writes the URL to `/etc/intern-dashboard-url`. Open it from any device on your tailnet. No Tailscale? Tunnel in: `ssh -L 9119:127.0.0.1:9119 <user>@<pi>`, then open `http://127.0.0.1:9119`.

With the firewall on, SSH the Pi **over the tailnet** (`ssh <user>@<tailnet-ip>`) — LAN port 22 is locked.

## Notes & gotchas (baked into the script)

- **Trixie** uses NetworkManager — `wlan0` is marked unmanaged just before the AP switch (`eth0` stays NM-managed); the AP/STA scripts use `nmcli`, not `systemctl stop NetworkManager`.
- Pi 5 has **no RTC** — the script waits for NTP sync before any TLS download.
- `intern-server` needs the **SPI0 bus** (`/dev/spidev0.0`) to boot; `stage_enable_spi` turns it on at runtime *and* in `config.txt`, so the backend comes up without a reboot. (The bus exists on every Pi 5; an LED ring being physically absent is irrelevant.)
- The **dashboard** is tailnet-only via `tailscale serve :443 → Caddy :9080 → :9119`, with Caddy rewriting **Host, Origin, and X-Forwarded-Proto** to satisfy the dashboard's anti-DNS-rebinding guard (including the chat/events **WebSocket**). Standard port 443 (not :8443) matters — **iCloud Private Relay only relays 80/443**, so a non-standard port trips up iOS Safari.
- The **firewall** (`stage_firewall`, on unless `SKIP_FIREWALL=1`) locks `22/80/443/5000/8080` to loopback + `tailscale0` + the AP subnet, so SSH and the backends are tailnet-only. It does **not** enable Tailscale SSH (that needs a tailnet ACL `ssh` rule and would lock out a firewalled device); use the regular sshd over the tailnet.
- **Hermes auxiliary tasks** are pinned to OpenRouter so Hermes never probes its hardcoded Nous inference fallback (which 402s without Nous credits).
- **Rabbit R1** (`stage_r1_shim`): the [`r1_shim`][r1-shim] adapter is **not** an upstream Hermes feature — the script copies it in and `git apply`s a version-pinned patch to the Hermes checkout. Those are working-tree edits, so a `hermes update` wipes them; re-run this script to re-apply. The shim runs on `:18790` (the `:18789` stub serves `intern-server`). A fixed token keeps the pairing QR stable across reboots; `intern-r1-qr.service` regenerates it on each gateway start and it shows as a 🐰 tile in the dashboard. Set `R1_SHIM_ENABLED=0` to skip the channel.
- **Hermes v0.16.0** quirks the script handles: `gateway install` prompts twice (fed `y`); `dashboard` dropped `--tui` (uses `--skip-build` to serve the prebuilt web dist).
- `hermes update` is broken out of the box (stale single-branch pin) — bump versions by fetching the tag explicitly (`git -C /usr/local/lib/hermes-agent fetch origin 'refs/tags/<tag>:refs/tags/<tag>'`) then re-running the installer (or bump `HERMES_BRANCH` and re-run this script).

The inline comments in `setup` carry the full rationale for each stage.

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — Nous Research
- [r1-hermes-shim][r1-shim] — the Rabbit R1 channel

[r1-shim]: https://github.com/iammatthias/r1-hermes-shim

## License

MIT
