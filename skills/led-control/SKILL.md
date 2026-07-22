---
name: led-control
description: Control the 8-pixel WS2812 LED ring when the user asks for a SPECIFIC color (e.g. "yellow", "red", "turn on color X", "enable X light"), an LED effect, or turning LEDs off. Do NOT use for ambiance/activity lighting (use scene) or meeting/privacy requests (use quiet-mode).
---

# LED Control

## Quick Start
Control the LED ring directly via the Autonomous HAL at `http://127.0.0.1:5001`. Use this skill only when the user requests a specific color, a named effect, or lights off. There are no reply markers on this stack: every LED action is a `curl` call from the bash tool.

## Workflow
1. Determine the user's intent:
   - Specific color: `POST /led/solid`
   - Effect: `POST /led/effect`
   - Turn off: `POST /led/off`
2. Fire the curl call.
3. Confirm the action to the user in one short sentence. Never narrate the curl.

## How to Control LEDs

### Solid color
```bash
curl -s -X POST http://127.0.0.1:5001/led/solid \
  -H 'Content-Type: application/json' \
  -d '{"color":[255,220,0]}'
```
Color is an RGB array `[R, G, B]`. On this HAL, `/led/solid` stops any running effect internally before filling the strip (verified in the HAL source, `routes/led.py`), so a single call is safe: no flicker, no separate stop call needed. The upstream project needed an explicit effect-stop first; this HAL does not, and it has no `/led/effect/stop` endpoint anyway.

### Effect
```bash
curl -s -X POST http://127.0.0.1:5001/led/effect \
  -H 'Content-Type: application/json' \
  -d '{"effect":"breathing","color":[255,180,100],"speed":0.5}'
```
- `effect` (required): name from the table below
- `color` (optional): RGB array
- `speed` (optional): 0.1 (slow) to 5.0 (fast), default 1.0

### Turn off / stop an effect
```bash
curl -s -X POST http://127.0.0.1:5001/led/off \
  -H 'Content-Type: application/json' \
  -d '{}'
```
`/led/off` also stops any running effect. To stop an effect without picking a new state, this is the call.

### Read current state
```bash
curl -s http://127.0.0.1:5001/led/color
```
Returns `{"on":..., "color":[r,g,b], "hex":..., "brightness":..., "effect":...}`. Use it to check what the ring is doing before you claim anything about it.

### Available effects

| Effect | Description | Best for |
|---|---|---|
| `breathing` | Slow fade in/out with given color | Relaxation, idle ambient |
| `candle` | Warm flickering like a real candle | Cozy evening |
| `rainbow` | Hue cycle across all pixels | Fun, party, showing off |
| `blink` | Simple on/off flash of the color | Quick attention, acknowledgment |
| `pulse` | Radial brightness wave | Attention, heartbeat, alive feeling |
| `notification_flash` | 3 quick flashes then auto-stops | Alerts, timer done, reminders |

### Color suggestions

| Color name | RGB |
|---|---|
| White | `[255, 255, 255]` |
| Yellow | `[255, 220, 0]` |
| Warm white | `[255, 180, 100]` |
| Orange | `[255, 100, 0]` |
| Red | `[255, 0, 0]` |
| Green | `[0, 200, 80]` |
| Blue | `[0, 150, 255]` |
| Purple | `[100, 50, 200]` |
| Pink | `[255, 80, 150]` |

## Examples

Input: "Make it purple" / "turn on purple"
Action: `curl -s -X POST http://127.0.0.1:5001/led/solid -H 'Content-Type: application/json' -d '{"color":[100,50,200]}'`
Reply: Purple it is.

Input: "Do a breathing light with warm color"
Action: `curl -s -X POST http://127.0.0.1:5001/led/effect -H 'Content-Type: application/json' -d '{"effect":"breathing","color":[255,180,100],"speed":0.5}'`
Reply: Breathing warm glow, running.

Input: "Rainbow mode!"
Action: `curl -s -X POST http://127.0.0.1:5001/led/effect -H 'Content-Type: application/json' -d '{"effect":"rainbow","speed":1.0}'`
Reply: Rainbow's on.

Input: "Turn off the lights"
Action: `curl -s -X POST http://127.0.0.1:5001/led/off -H 'Content-Type: application/json' -d '{}'`
Reply: LEDs off.

Input: "I want to relax" / "reading mode" / "goodnight"
Action: Do NOT use this skill. Use the **scene** skill instead.

Input: "I'm in a meeting" / "need some privacy"
Action: Do NOT use this skill. Use the **quiet-mode** skill instead.

## Error Handling
- If curl fails or returns non-2xx, tell the user: "I couldn't control the LEDs right now. The hardware service may be unavailable." Do not retry more than once.
- If the user requests an unknown effect name, pick the closest match from the table or tell them what's available.

## Rules
- **Always include a JSON body, even for no-argument commands.** `POST /led/off` gets `-d '{}'`. A POST without a body can be rejected and the light will NOT turn off.
- **"Turn on color X" / "set light X" / "change color X" = THIS skill.** Any request naming a color (yellow, red, green, purple, white, orange, pink) routes here, not to scene.
- **No stop-before-solid dance.** On this HAL `/led/solid` stops the running effect itself. One call, done.
- **Solid colors = full requested brightness.** For dim/ambient lighting, use the scene skill (it pre-scales brightness into the RGB values).
- **Quiet hours 22:00 to 07:00 are enforced by the HAL itself** (brightness clamp). Do not fight it: never resend brighter values to compensate, never report the LED as broken when it looks dim at night. If the user asks why it's dim, explain the night clamp.
- **Effects run until stopped.** Starting a new effect auto-stops the previous one. `notification_flash` auto-stops on its own.
- For "make it cozy" or "candle light": use the `candle` effect, not a static orange.
- For "breathing" or "pulsing" requests: use the matching effect.
- Low speed (0.3 to 0.5) for calm moods, high speed (2.0 to 3.0) for energy.
- **Do NOT use for activity/ambiance lighting** (sleeping, relaxing, reading, focus, movie): use the **scene** skill.
- **Do NOT use for meeting/call/privacy requests**: use the **quiet-mode** skill.
- Never narrate the workflow or paste curl output into your reply. Confirm in one short sentence.
