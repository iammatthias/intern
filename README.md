# intern

![Autonomous Intern](https://cdn.autonomous.ai/production/ecm/260605/intern(3).webp)

The [Autonomous Intern](https://www.autonomous.ai/ai-gadgets/intern) is an agentic Raspberry Pi in a fun form factor.

This script bootstraps a fresh Debian Trixie install with **Hermes** (Nous Research), a **Caddy** web layer, **Tailscale** for secure remote access, and an optional **Rabbit R1** channel. Memory is Hermes' own built-in store, so there's no external database to run.

One script, `setup`, provisions the whole stack. It's idempotent enough to re-run, and auto-detects whether to run Wi-Fi onboarding (captive-portal access point) or keep an existing connection.

It's a reworked version of the stock [`setup.sh`](https://cdn.autonomous.ai/intern/setup.sh) Autonomous ships (their [quick start](https://docs.autonomous.ai/intern/setup-intern/quick-start) and the [autonomous-intern](https://github.com/autonomous-ai/autonomous-intern) repo cover the stock path). The main swaps are OpenClaw for Hermes and nginx for Caddy.

## What it installs

| Component | Role |
|-----------|------|
| **Caddy** | Serves the setup web UI on `:80`, reverse-proxies `/api/*` to `intern-server:5000`, plus a loopback `:9080` Host/Origin-rewrite hop for the dashboard |
| **intern backend** | The Autonomous `intern-server` (LED ring on SPI0, Wi-Fi onboarding API) |
| **Hermes agent** | Gateway as a systemd service (`hermes-gateway`), pinned to a release tag (default `v2026.6.5`, == v0.16.0) |
| **Memory** | Hermes' built-in store: a ~2k `MEMORY.md` plus the skills and procedural memory it writes itself. No vector DB, no Docker. See [Memory](#memory) |
| **Tailscale** | SSH over the tailnet (regular sshd, key auth), and the Hermes dashboard published tailnet-only on standard HTTPS `:443` |
| **Hermes dashboard** | Web UI for config, API keys, and chat (`hermes-dashboard`, loopback `:9119`) |
| **LED bridge** | Hermes lifecycle hooks post to `intern-server`'s `/api/led` so the ring tracks what the agent is doing (idle, thinking, working) |
| **Gateway shim** | `intern-gateway-shim` answers the OpenClaw `:18789` WS handshake so `intern-server` stops reconnect-looping under Hermes |
| **Rabbit R1 channel** | Optional. The third-party [`r1_shim`][r1-shim] adapter on `:18790`, plus a pairing QR rendered into the dashboard as a tile |
| Base plumbing | locale, RPi-5 Wi-Fi stability, SPI enable (runtime and reboot), AP/STA Wi-Fi switching (hostapd/dnsmasq), OTA backend, firewall |

## Memory

Hermes brings its own memory, and it's simple. The agent keeps a ~2k `MEMORY.md` current and writes its own skills and procedural memory as it works. There's no vector database and no Docker stack to run.

## Requirements

- **Raspberry Pi 5** with Raspberry Pi OS **Trixie** (Debian 13), 64-bit, on an SD card.
- Internet during setup (Ethernet, a pre-baked Wi-Fi, or onboard via the captive portal).
- Run as **root**.
- An **OpenRouter** (or other OpenAI-compatible) API key for the LLM. A **Tailscale** auth key is optional.

## Usage

On a fresh Pi 5, as root:

```sh
OPENROUTER_API_KEY=sk-or-... \
TS_AUTHKEY=tskey-... \
  sudo -E bash setup
```

A desk or dev box you reach over Wi-Fi (keeps `wlan0` and SSH up, no AP switch, no firewall, no reboot):

```sh
SKIP_FIREWALL=1 SKIP_REBOOT=1 \
OPENROUTER_API_KEY=sk-or-... \
TS_AUTHKEY=tskey-... \
  sudo -E bash setup
```

### Key environment overrides

| Var | Purpose |
|-----|---------|
| `TS_AUTHKEY` / `TS_HOSTNAME` | Tailscale unattended join and tailnet hostname (default `intern-<serial>`) |
| `OPENROUTER_API_KEY` | LLM key for Hermes on the unpaired (bring-your-own) path |
| `HERMES_MODEL` / `HERMES_FALLBACK_MODEL` | optional. Pin a chat model. Default is unset, so you pick it in the dashboard |
| `HERMES_BRANCH` | Hermes release tag (default `v2026.6.5`) |
| `R1_SHIM_ENABLED` / `R1_SHIM_TOKEN` / `R1_SHIM_PORT` | Rabbit R1 channel: on by default, token auto-generated (fixed), port `18790` |
| `R1_SHIM_REPO_RAW` | Source of the `r1_shim` adapter and Hermes patch ([iammatthias/r1-hermes-shim][r1-shim]) |
| `AP_MODE` | `auto` (default), `force`, or `skip`. Captive-portal onboarding vs. use existing Wi-Fi |
| `SKIP_AP` / `SKIP_FIREWALL` / `SKIP_REBOOT` | desk/dev opt-outs |
| `WIFI_SSID` / `WIFI_PASS` | provision Wi-Fi up front so a flashed image comes up online |
| `INTERN_SKILLS_ZIP_URL` / `GITHUB_TOKEN` | onboarding-skill source (best-effort, non-fatal) |

## Reaching the dashboard

With Tailscale up, the script publishes the Hermes dashboard tailnet-only at `https://<your-tailnet-fqdn>/` (standard port 443) and writes the URL to `/etc/intern-dashboard-url`. Open it from any device on your tailnet. Without Tailscale, tunnel in with `ssh -L 9119:127.0.0.1:9119 <user>@<pi>`, then open `http://127.0.0.1:9119`.

With the firewall on, SSH the Pi over the tailnet (`ssh <user>@<tailnet-ip>`). LAN port 22 is locked.

## Notes and gotchas (baked into the script)

- **Trixie / NetworkManager.** `wlan0` is set unmanaged just before the AP switch (`eth0` stays managed); the AP/STA scripts use `nmcli`.
- **No RTC.** The script waits for NTP sync before any TLS download.
- **SPI0.** `intern-server` won't boot without `/dev/spidev0.0`. `stage_enable_spi` enables it at runtime and in `config.txt`, so the backend comes up without a reboot. The bus is there on every Pi 5, with or without the LED ring.
- **Dashboard is tailnet-only** via `tailscale serve :443` → Caddy `:9080` → `:9119`. Caddy rewrites Host/Origin/X-Forwarded-Proto for the dashboard's anti-DNS-rebinding guard. Port 443, not :8443, is deliberate: iCloud Private Relay only relays 80/443.
- **Firewall** (`stage_firewall`, on unless `SKIP_FIREWALL=1`) locks `22/80/443/5000/8080` to loopback, `tailscale0`, and the AP subnet. It doesn't turn on Tailscale SSH, so use the regular sshd over the tailnet.
- **Auxiliary tasks pinned to OpenRouter** so Hermes never probes its Nous inference fallback, which 402s without Nous credits.
- **Rabbit R1** (`stage_r1_shim`) is a third-party [`r1_shim`][r1-shim], not upstream Hermes. The script patches it into the Hermes checkout, so a `hermes update` wipes it; re-run to re-apply. Runs on `:18790`. A fixed token keeps the pairing QR stable, shown as a 🐰 tile. `R1_SHIM_ENABLED=0` skips it.
- **`hermes update` is broken** out of the box (stale single-branch pin). Bump `HERMES_BRANCH` and re-run, or fetch the tag by hand.

The inline comments in `setup` carry the full rationale for each stage.

## Credits

- [autonomous-intern](https://github.com/autonomous-ai/autonomous-intern) and the stock [`setup.sh`](https://cdn.autonomous.ai/intern/setup.sh), Autonomous. This is a rework of that.
- [Hermes Agent](https://github.com/NousResearch/hermes-agent), Nous Research
- [r1-hermes-shim][r1-shim], the Rabbit R1 channel

[r1-shim]: https://github.com/iammatthias/r1-hermes-shim

## License

MIT
