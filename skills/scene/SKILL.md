---
name: scene
description: Activate predefined lighting scene presets (reading, focus, relax, movie, night, energize) when the user asks for activity-based or environment lighting. Scenes bake brightness and color temperature into concrete RGB values. Do NOT use for specific colors (use led-control) or meeting/privacy requests (use quiet-mode).
---

# Lighting Scenes

## Quick Start
Activate predefined lighting presets tuned for activities. Use this for ALL activity-based or environment lighting requests ("reading mode", "goodnight", "movie time", "I want to relax").

There is no scene engine on this stack. Each scene is a concrete `curl` call to the Autonomous HAL at `http://127.0.0.1:5001`, with brightness pre-multiplied into the RGB values (the HAL takes raw RGB only). The values come from the upstream project's scene presets, scaled by their brightness factor.

## Available scenes

| Scene | Feel | Call | RGB (brightness baked in) |
|---|---|---|---|
| `reading` | 80%, ~4000K neutral | `/led/solid` | `[204, 167, 130]` |
| `focus` | 70%, ~4200K warm-neutral | `/led/solid` | `[178, 150, 119]` |
| `relax` | 40%, ~2700K warm, slow breathing | `/led/effect` breathing, speed 0.3 | `[102, 66, 35]` |
| `movie` | 15%, ~2400K dim amber | `/led/solid` | `[38, 22, 8]` |
| `night` | 5%, ~1800K deep amber, blue-free | `/led/solid` | `[13, 5, 0]` |
| `energize` | 100%, ~5000K daylight | `/led/solid` | `[255, 228, 206]` |

## How to activate

Solid scenes (reading, focus, movie, night, energize):
```bash
curl -s -X POST http://127.0.0.1:5001/led/solid \
  -H 'Content-Type: application/json' \
  -d '{"color":[204,167,130]}'
```

Relax (the one effect scene):
```bash
curl -s -X POST http://127.0.0.1:5001/led/effect \
  -H 'Content-Type: application/json' \
  -d '{"effect":"breathing","color":[102,66,35],"speed":0.3}'
```

Scene off ("back to normal" / "turn off scene"):
```bash
curl -s -X POST http://127.0.0.1:5001/led/off \
  -H 'Content-Type: application/json' \
  -d '{}'
```

## Scene vs LED Control

| Request | Skill |
|---|---|
| "reading mode", "I need to focus", "movie time" | **scene** |
| "I want to relax", "let me chill", "unwind" | **scene** (`relax`) |
| "goodnight", "time to sleep", "going to bed" | **scene** (`night`) |
| "make it purple", "yellow light", any named color | **led-control** |
| "candle light", "rainbow mode", any named effect | **led-control** |
| "turn off the light" | **led-control** (`/led/off`) |
| "back to normal", "turn off scene" | **scene** off (`/led/off`) |
| "I'm in a meeting", "privacy please" | **quiet-mode** |

## Examples

Input: "Reading mode"
Action: solid `[204,167,130]`
Reply: Reading mode on, neutral white at 80 percent.

Input: "Goodnight" / "time to sleep"
Action: solid `[13,5,0]`
Reply: Night mode. Sweet dreams.

Input: "I want to relax"
Action: breathing `[102,66,35]` speed 0.3
Reply: Relax mode, warm and slow.

Input: "Movie time"
Action: solid `[38,22,8]`
Reply: Movie mode, dim amber.

Input: "Make it purple"
Action: Do NOT use this skill. Use **led-control**.

## Error Handling
- If curl fails or returns non-2xx, tell the user: "I couldn't change the lighting right now. The hardware service may be unavailable."
- If the user asks for a scene that doesn't exist, suggest the closest one from the table.

## Rules
- **Scene = brightness + color in one RGB value.** This is why ambiance requests route here: led-control's colors are full brightness, useless for sleep or relax.
- **"sleepy", "goodnight", "time to sleep", "going to bed"**: ALWAYS `night` (ultra dim, blue-free).
- **"relax", "chill", "unwind"**: `relax`.
- **"watch a movie", "movie"**: `movie`.
- **Quiet hours 22:00 to 07:00 are enforced by the HAL itself** (brightness clamp). Do not fight it. The `night` values are already below the clamp; brighter scenes will simply come out dimmer at night, which is correct.
- Switching scenes is just another call, the update is immediate.
- Always include the JSON body; `/led/off` gets `-d '{}'`.
- For custom lighting beyond these presets, use **led-control** with specific RGB values.
- Never narrate the workflow or paste curl output. Confirm in one short sentence.
