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
| **HAL** | Autonomous OS's open hardware layer ([autonomous-ai/autonomous-os](https://github.com/autonomous-ai/autonomous-os) `os/hal`, pinned commit, loopback `:5001`). Drives the WS2812 ring directly over spidev with per-frame safety clamps (brightness ceiling, quiet hours 22:00-07:00) from our `devices/intern-v1/SAFETY.md`. Replaces the closed intern-server LED path and the `:18789` gateway shim |
| **Device contract** | `devices/intern-v1/` declares the hardware (light + system required, audio/sensing optional for future hardware); CI runs upstream's conformance suite against it |
| **intern backend** | The Autonomous `intern-server`, now only for the captive-portal Wi-Fi onboarding API. Retired (stopped + disabled) once the device is online and HAL owns the ring |
| **Hermes agent** | Gateway as a systemd service (`hermes-gateway`), pinned to a fixed upstream `main` commit (currently v0.18.2-era, past the v2026.7.7.2 tag) |
| **Presync** | `intern-hermes-presync` re-asserts the OS-owned Hermes state (approvals off, hooks block, SOUL.md block, gateway hook) on every boot and setup re-run, restarting the gateway only on change |
| **Skills** | `skills/` (adapted from Autonomous OS first-party skills): led-control, scene, quiet-mode, mood, habit, wellbeing, installed into `~/.hermes/skills/` |
| **Memory** | Hermes' built-in store: a ~2k `MEMORY.md` plus the skills and procedural memory it writes itself. No vector DB, no Docker. See [Memory](#memory) |
| **Tailscale** | SSH over the tailnet (regular sshd, key auth), and the Hermes dashboard published tailnet-only on standard HTTPS `:443` |
| **Hermes dashboard** | Web UI for config, API keys, and chat (`hermes-dashboard`, loopback `:9119`) |
| **LED bridge** | Hermes lifecycle hooks post looks to the HAL (`/led/effect`) so the ring tracks the agent (idle, thinking, working); a gateway hook adds a message-ack flash and error pulses; `intern-hermes-health` shows agent-down when the gateway dies |
| **Rabbit R1 channel** | Optional. rabbit's official rabbit-agent node (native rabbitOS support, needs a one-time token from [rabbithole](https://hole.rabbit.tech)). The old third-party [`r1_shim`][r1-shim] path is archived and off by default |
| Base plumbing | locale, RPi-5 Wi-Fi stability, SPI enable (runtime and reboot), AP/STA Wi-Fi switching (hostapd/dnsmasq), OTA backend, firewall, journald cap + tmpfs /tmp, nightly backups, power sentinel, build provenance stamp, end-of-run QC gate |

## Memory

Hermes brings its own memory, and it's simple. The agent keeps a ~2k `MEMORY.md` current and writes its own skills and procedural memory as it works. There's no vector database and no Docker stack to run.

The pinned build also lets the agent batch its edits: it can add, replace, and remove memory entries in one atomic call, so it spends far fewer turns keeping the file under budget.

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
| `HERMES_BRANCH` / `HERMES_REF` | Branch the installer clones (default `main`) and the commit it pins to (default: a v0.18.2-era `main` commit, what the live device runs). Set `HERMES_REF` empty to track the branch HEAD |
| `AUTONOMOUS_OS_REF` | Commit of [autonomous-os](https://github.com/autonomous-ai/autonomous-os) the HAL installs from (pinned, same discipline as `HERMES_REF`) |
| `HAL_DEVICE_TYPE` | Device declaration under `devices/` the HAL boots with (default `intern-v1`) |
| `RABBIT_AGENT_TOKEN` | Rabbit R1 channel: node registration token from [rabbithole](https://hole.rabbit.tech) (Settings → Nodes → Register Node). One-time; re-runs don't need it |
| `R1_SHIM_ENABLED` / `R1_SHIM_TOKEN` / `R1_SHIM_PORT` | Legacy R1 shim channel: off by default now that rabbitOS supports Hermes natively. Set `R1_SHIM_ENABLED=1` only for a device still paired via the shim QR (fixed token, port `18790`) |
| `R1_SHIM_REPO` | Plugin repo for the legacy shim ([iammatthias/r1-hermes-shim][r1-shim], archived) |
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
- **SPI0.** The LED path (HAL, and `intern-server` during AP onboarding) needs `/dev/spidev0.0`. `stage_enable_spi` enables it at runtime and in `config.txt`, so everything comes up without a reboot. The bus is there on every Pi 5, with or without the LED ring.
- **One SPI owner.** HAL and `intern-server` must never both drive the strip (interleaved frames are garbage). `stage_hal` stops and disables `intern.service` + `intern-gateway-shim.service` after HAL passes its health gate, and rolls back to them if it doesn't. On the AP-onboarding path HAL installs but stays stopped until a re-run after onboarding.
- **HAL install is big.** `uv sync --extra hardware` pulls the full upstream dependency set (vision/audio included, so those capabilities mount the day the hardware exists): budget 20-40 minutes and a few GB on first provision. uv brings its own CPython 3.12.
- **Dashboard is tailnet-only** via `tailscale serve :443` → Caddy `:9080` → `:9119`. Caddy rewrites Host/Origin/X-Forwarded-Proto for the dashboard's anti-DNS-rebinding guard. Port 443, not :8443, is deliberate: iCloud Private Relay only relays 80/443.
- **Firewall** (`stage_firewall`, on unless `SKIP_FIREWALL=1`) locks `22/80/443/5000/8080` to loopback, `tailscale0`, and the AP subnet. It doesn't turn on Tailscale SSH, so use the regular sshd over the tailnet.
- **Auxiliary tasks pinned to OpenRouter** so Hermes never probes its Nous inference fallback, which 402s without Nous credits.
- **Rabbit R1** (`stage_rabbit_agent`) uses rabbit's own agent integration: a rabbit-agent node runs on the Pi as root (so it shares `/root/.hermes` with every other channel) and connects out to rabbit's cloud, which means the R1 works away from your LAN. Register the node at [rabbithole](https://hole.rabbit.tech) (Settings → Nodes → Register Node) and pass the token as `RABBIT_AGENT_TOKEN` once; rabbit's installer keeps itself alive via its own cron entries. Setup doc: [Agents on rabbit r1](https://www.rabbit.tech/support/article/agents-on-rabbit-r1). The old LAN/QR path (`stage_r1_shim`, the archived [`r1_shim`][r1-shim] plugin on `:18790`) is off by default; `R1_SHIM_ENABLED=1` keeps it for a device already paired that way.
- **`hermes update` works** on installs from this script (it clones the `main` branch, so `origin/main` exists). To move the pin, bump `HERMES_REF` and re-run, or `hermes update --yes --branch main` on the device.

The inline comments in `setup` carry the full rationale for each stage.

## Credits

- [autonomous-intern](https://github.com/autonomous-ai/autonomous-intern) and the stock [`setup.sh`](https://cdn.autonomous.ai/intern/setup.sh), Autonomous. This is a rework of that.
- [autonomous-os](https://github.com/autonomous-ai/autonomous-os), Autonomous. The HAL (`os/hal`, cloned at provision time, GPL-3: it is a [LeLamp](https://github.com/humancomputerlab/LeLamp) fork), the device contract our `devices/intern-v1/` declares against, and the first-party skills our `skills/` adapt (Apache-2.0)
- [Hermes Agent](https://github.com/NousResearch/hermes-agent), Nous Research
- [Agents on rabbit r1](https://www.rabbit.tech/support/article/agents-on-rabbit-r1), rabbit's native Hermes integration, the current R1 channel
- [r1-hermes-shim][r1-shim], the R1 channel before rabbit shipped native support (archived)

[r1-shim]: https://github.com/iammatthias/r1-hermes-shim

## License

MIT
