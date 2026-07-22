---
name: quiet-mode
description: Meeting/privacy/quiet requests. MUST trigger on explicit "meeting", "on a call", "privacy", "quiet mode", "do not disturb". Sets the LED ring to a dim dark-red breathing indicator, records quiet state in a file, and suppresses non-urgent proactive Telegram messages until the user says "back" or "done". Explicit requests only, never a bare overheard word.
---

# Quiet Mode

This device has no microphone or speaker, so there is nothing to mute. What carries over from the upstream voice skill is the intent: when the user is in a meeting, on a call, or wants to be left alone, the intern goes visually quiet (dim dark-red breathing ring, the upstream privacy-indicator look) and stops proactive pings until told otherwise.

State file: `/root/.hermes/intern-data/quiet-mode.json`
Shape: `{"active": true, "until": "<ISO timestamp>", "reason": "meeting"}`

## Explicit-request guard (read FIRST)

R1 voice transcriptions can clip, and chat messages mention meetings in passing. **Never activate quiet mode from a bare word.** Only a clear, complete, present-tense request counts:

- Activates: "I'm going into a meeting", "I'm on a call", "quiet mode please", "need some privacy", "do not disturb for an hour"
- Does NOT activate: "the meeting ran long" (past tense, reporting), "I have a meeting at 3" (future; you may offer to set it up then), "that call was rough", the word "quiet" inside a sentence about something else

**"back" ≠ "quiet". Read the exact words.** "I'm back" / "done" / "meeting's over" lifts quiet mode, never sets it.

## Activate

Trigger table (MANDATORY: run the flow, don't just acknowledge in text):

| User says | Action |
|---|---|
| "I'm in a meeting" / "going into a meeting" / "on a call" | activate, reason `meeting` |
| "privacy" / "need privacy" / "leave me alone for a bit" | activate, reason `privacy` |
| "quiet mode" / "do not disturb" / "go quiet" | activate, reason `quiet` |

Flow (one bash call for steps 1 and 2 is fine):

1. Set the ring to the quiet indicator:
```bash
curl -s -X POST http://127.0.0.1:5001/led/effect \
  -H 'Content-Type: application/json' \
  -d '{"effect":"breathing","color":[140,0,0],"speed":0.8}'
```
2. Record the state:
```bash
mkdir -p /root/.hermes/intern-data
printf '%s\n' '{"active":true,"until":"'"$(date -Is -d '+60 minutes')"'","reason":"meeting"}' \
  > /root/.hermes/intern-data/quiet-mode.json
```
   - User named a duration or end time ("for two hours", "until 4"): use that for `until`.
   - No duration given: default to now + 60 minutes.
3. Confirm in one short sentence, always including how to lift it: "Going quiet. Say 'I'm back' when you're done."

## Deactivate

| User says | Action |
|---|---|
| "I'm back" / "done" / "meeting's over" / "back to normal" | deactivate |

Flow:

1. Clear the state:
```bash
printf '%s\n' '{"active":false}' > /root/.hermes/intern-data/quiet-mode.json
```
2. Restore the ring:
```bash
curl -s -X POST http://127.0.0.1:5001/led/restore \
  -H 'Content-Type: application/json' -d '{}'
curl -s http://127.0.0.1:5001/led/color
```
   If the color check still shows the dark-red breathing look (the quiet effect may have been saved as user state), fall back to `POST /led/off` with `-d '{}'`.
3. Confirm briefly. If any non-urgent messages were held during quiet mode, deliver them now as one short digest, not a flood.

## Gate for proactive sends (all skills)

Before ANY proactive message (cron-driven Telegram nudges, wellbeing check-ins, anything the user didn't just ask for), check the state file:

```bash
cat /root/.hermes/intern-data/quiet-mode.json 2>/dev/null
```

- `active` is true AND now is before `until`: hold all non-urgent proactive messages. Replying to a message the user just sent is always fine.
- Now is past `until`: quiet mode has expired. Treat as inactive and rewrite the file to `{"active":false}` on the next write opportunity.
- File missing or `active` false: send normally.
- Exceptions that pass through quiet mode: alerts the user explicitly asked for ("tell me when the build finishes even if I'm in a meeting") and genuine emergencies (hardware failure warnings). Everything else waits.

## Rules

- Explicit requests only. When in doubt, do nothing; a wrongly-triggered quiet mode is worse than asking.
- The quiet indicator is intentionally dim. Quiet hours 22:00 to 07:00 are enforced by the HAL brightness clamp on top of that; do not fight it.
- Always include the JSON body on every curl, `-d '{}'` for no-argument endpoints.
- Never narrate the workflow (no "writing the state file now"). One short confirmation sentence, that's it.
- Always tell the user how to lift quiet mode when you set it.
