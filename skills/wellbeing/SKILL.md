---
name: wellbeing
description: Proactive time-window check-ins over Telegram: morning greeting, lunch and dinner reminders, late-evening sleep wind-down. Runs on Hermes cron ticks and on user messages. Every route is gated by a per-user JSONL ledger (once per day / once per window) and by quiet mode. No sensors on this stack, so timing plus the log is all the evidence there is.
---

# Wellbeing

The upstream skill coached hydration, breaks, and posture off camera activity events. This device has no camera, so only the time-window routes survive: morning greeting, meal reminders, sleep wind-down. What DOES carry over intact is the discipline: a ledger row per fired route, once-per-day and once-per-window idempotency, and "trust the log, not memory".

> **OUTPUT RULE:** never narrate the workflow. No route names, no ledger talk, no "checking your log" in the reply. The user gets 1 to 3 natural sentences, or nothing.

## Triggers

| Trigger | What to do |
|---|---|
| Hermes cron wellbeing tick | run the decision table below, send proactively via Telegram if a route fires |
| any user message | run the decision table; if a route fires, fold it naturally into your reply instead of a separate ping |
| user asks directly ("should I eat?") | just answer, no gate rows, no route |

Proactive delivery is Telegram. R1 and the dashboard are pull-style channels; don't push to them.

## Storage

Ledger: `/root/.hermes/intern-data/wellbeing/<user>.jsonl` (lowercase user, `unknown` if unattributed).

Row shape (append one row per fired route, in the same bash call batch as anything else you're writing):

```bash
mkdir -p /root/.hermes/intern-data/wellbeing
printf '%s\n' '{"ts":"'"$(date -Is)"'","date":"'"$(date +%F)"'","hour":'"$(date +%-H)"',"action":"morning_greeting","notes":"<the sentence you sent>"}' \
  >> /root/.hermes/intern-data/wellbeing/<user>.jsonl
```

Actions you may write: `morning_greeting`, `meal_reminder` (with an extra `"trigger":"lunch"` or `"trigger":"dinner"` field), `sleep_winddown`. Never invent new actions. Keep `notes` plain: no double quotes, no braces.

## Pre-flight: read the log, not memory

One bash call, batched:

```bash
TODAY=$(date +%F)
echo '---wellbeing---'
grep "$TODAY" /root/.hermes/intern-data/wellbeing/<user>.jsonl 2>/dev/null
echo '---habits---'
grep "$TODAY" /root/.hermes/intern-data/habits/<user>.jsonl 2>/dev/null
echo '---quiet---'
cat /root/.hermes/intern-data/quiet-mode.json 2>/dev/null
```

**Trust the log, not memory.** If today's rows contain no `morning_greeting`, no greeting has happened, whatever you remember saying. If the grep returns nothing, nothing fired today.

## Decision table (first match wins, one route per turn)

| # | Condition | Route | Output |
|---|---|---|---|
| 1 | quiet-mode file has `active:true` and now is before `until` | **silent** | hold everything non-urgent (see quiet-mode skill) |
| 2 | hour in [5, 11) AND no `morning_greeting` row today AND (this is the user's first message today, or the morning cron tick) | **morning-greeting** | `reference/morning-greeting.md`, then log `morning_greeting` |
| 3 | hour >= 21 AND no `sleep_winddown` row today AND the user was active in the last ~90 minutes (a message of theirs, any channel) | **sleep-winddown** | `reference/sleep-winddown.md`, then log `sleep_winddown` |
| 4 | inside a meal window (lunch 11:30 to 13:30, dinner 18:30 to 20:30) AND no meal signal this window | **meal-reminder** | `reference/meal-reminder.md`, then log `meal_reminder` with the window as `trigger` |
| 5 | anything else | **silent** | no reply, no row |

**Meal signal** (row 4 gate) means either of these inside the current window today:
- a `meal_reminder` row with the same `trigger` in the wellbeing ledger (you already asked), or
- a `meal` or `coffee` intent row in the habits log (the user already said "going to lunch"; habit Flow D logged it). Never ask "eaten yet?" right after they told you they're eating.

**Sleep evidence** (row 3): with no sensors, a recent message is the only proof the user is awake. No message in the last ~90 minutes means they may already be asleep; a proactive ping would wake them. Stay silent.

## Rules

- **One route per turn.** First matching row, then stop.
- **The row you append IS the gate.** `morning_greeting` suppresses row 2 for the rest of the day, `sleep_winddown` for the night, `meal_reminder` for that window (lunch and dinner gate independently).
- If the append fails (disk error, path typo), fix and retry once. The row must land or the skill will nag forever.
- Never narrate the routing decision.
- LED is not part of these routes. If a wind-down chat leads to "yeah, wrapping up", you may offer the night scene (scene skill), but never change the light uninvited. Any LED use respects the HAL's 22:00 to 07:00 brightness clamp.

## Habit enrichment (only when a route fires)

If a route is about to fire, you may read `/root/.hermes/intern-data/habits/<user>.patterns.json` (rebuild via habit Flow A only if missing or stale; its freshness guard makes that cheap). A moderate+ pattern matching the current window lets you phrase the line as observed ("you usually grab lunch around now") instead of generic. No pattern, or under 3 days of data: stay generic. **Never fabricate a pattern.** If you decided NOT to fire, never touch the patterns file.

## Phrasing (all routes)

Talk like a friend, not a wellness app. 1 to 3 sentences, warm, casual. Weave in at most ONE short health-context clause when it fits ("so you've got fuel for the afternoon", "you'll thank yourself in the morning"), never a lecture.

**Variety is non-negotiable.** Check your last few sent lines in this session and diverge: different opener, different angle, different length. Never speak a reference-table row verbatim, and never reuse the same health clause two days running. If you can't find a fresh angle, go shorter rather than recycle. Match the user's language.
