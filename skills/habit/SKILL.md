---
name: habit
description: Tracks and analyzes behavioral patterns (habits) per user from stated intents in chat and r1 transcripts ("going to lunch", "heading to bed"). Silently logs intents as they happen, builds patterns.json on demand or from Hermes cron, and answers questions about routines ("notice anything about my patterns?"). Also enriches wellbeing nudge phrasing. Never fires its own standalone nudge.
---

# Habit

Habits are **repeating behavioral patterns** derived from logged history. On this stack the history comes from what users SAY (Telegram, R1 transcripts, dashboard chat), not from sensors: there is no camera and no activity detection. This skill logs stated intents silently as they happen, then periodically distills them into per-user patterns other skills can consume.

> **OUTPUT RULE:** One short natural sentence at most, usually nothing. All computation, pattern math, and log reads stay in tool calls. NEVER output timestamps, deltas, frequency counts, or reasoning in the reply. **(Exception: open habit questions, Flow E, see `reference/open-question.md`.)**

## Storage

| File | What |
|---|---|
| `/root/.hermes/intern-data/habits/<user>.jsonl` | intent log, one JSON row per stated intent |
| `/root/.hermes/intern-data/habits/<user>.patterns.json` | computed patterns (Flow A output) |

User names are lowercase; unattributed senders collapse to `unknown`.

## Flows

| Flow | When to run | Details |
|---|---|---|
| **A: Build patterns** | answering habit questions; Hermes cron refresh; wellbeing asks for enrichment | `reference/build-patterns.md` |
| **D: Intent logging** | user states an intent NOW in any chat or transcript turn | inline below |
| **E: Open habit question** | user asks about someone's habits / patterns / routines | `reference/open-question.md` |

(Upstream flows B and C covered wellbeing sensor matching and music personalization; the matching-window table survives inside `reference/build-patterns.md`, the rest is gone with the sensors.)

## Flow D: Intent logging (the always-on flow)

When the user expresses intent for a daily activity NOW, log it silently and just respond naturally.

**Intent to action mapping:**

| User says | Action |
|---|---|
| "lunch", "dinner", "going to eat", "grab food" | `meal` |
| "coffee break", "grab a coffee", "getting coffee" | `coffee` |
| "good night", "going to sleep", "heading to bed" | `sleep` |
| "gym", "exercise", "workout", "going for a run" | `exercise` |

**How to log (one bash call):**

```bash
mkdir -p /root/.hermes/intern-data/habits
printf '%s\n' '{"ts":"'"$(date -Is)"'","date":"'"$(date +%F)"'","hour":'"$(date +%-H)"',"action":"meal","notes":"user said going to lunch"}' \
  >> /root/.hermes/intern-data/habits/<user>.jsonl
```

**Rules:**
- Log silently. Do NOT tell the user you're logging. Just respond naturally to what they said.
- Only log when the user states intent NOW. Past tense ("had lunch earlier") and general talk ("I should exercise more") don't count.
- One log per intent per conversation turn, no duplicates.
- `notes` stores a short paraphrase for debugging. Keep it plain: no double quotes, no braces.

## What is a habit?

A habit is a **time-anchored action** that repeats across multiple days. Strength labels:

| Frequency | Strength |
|---|---|
| < 0.50 | weak (skip for nudging) |
| 0.50 to 0.75 | moderate |
| > 0.75 | strong |

## Minimum data requirements

| Purpose | Min days | Min occurrences |
|---|---|---|
| Habit detection | 3 | 2 |
| Proactive nudge enrichment | 5 | 3 |

**With fewer than 3 days of data, there are no patterns, full stop.** If data is insufficient, say so or stay generic. **Never fabricate patterns.**

## Integration points

**wellbeing/SKILL.md:** when a wellbeing route is about to fire, it may read `<user>.patterns.json` (rebuilding via Flow A only if the file is missing or stale, the freshness guard in `reference/build-patterns.md` makes this cheap). A moderate+ pattern matching the current window lets wellbeing phrase the nudge as observed ("you usually grab lunch around now") instead of generic. Habit itself never speaks the nudge; wellbeing owns it.

**Hermes cron:** a periodic job may invoke Flow A per active user to keep patterns fresh. The freshness guard makes repeated runs free.

## Output examples

- Enrichment handed to wellbeing: "you usually head to lunch around now, everything okay?"
- When no data: nothing. Never guess or fabricate habits.
- Open questions: see `reference/open-question.md` for pattern / narrative / honest-gap modes.
