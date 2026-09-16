---
schema: autonomous.device.v1
id: intern-v1
name: Autonomous Intern (v1, community stack)
type: desk_agent
boards: [raspberry_pi_5]
gateway:
  default: hermes
  protocol: sse
capabilities:
  audio:   { routes: [audio, speaker, voice], required: false }
  sensing: { routes: [sensing], required: false }
  system:  { routes: [system], required: true }
  light:   { routes: [led], driver: ws2812, required: true, safety: SAFETY.md#light }
safety_ref: SAFETY.md
memory: { backend: local }
startup_volume: 100
---

# Autonomous Intern v1 (community stack)

The first-generation Intern hardware running the iammatthias/intern stack: a Pi 5 with
an 8-pixel WS2812 ring, no camera, no motion, no display, and (on v1) no mic or speaker.
The brain is Hermes; channels are Telegram, Rabbit R1 (via rabbit's own agent node), and
the Hermes dashboard.

`audio` and `sensing` are declared optional so the day a USB mic/speaker or a wm8960 hat
shows up, the HAL mounts those routes without a re-declaration. Until then the HAL boots
with `light` + `system` only.

## What the agent should assume

- No camera, no body, no screen. Expression is the LED ring and words.
- The job is agentic work (mail, calendar, tasks, research), not expressive companionship.
- The ring is driven through the HAL (`http://127.0.0.1:5001`); brightness ceilings and
  quiet hours are enforced there, below the agent.
