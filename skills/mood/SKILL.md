---
name: mood
description: Tracks the USER's mood only, as signal rows plus a synthesized decision row per trigger, from telegram, r1, and dashboard text. Do NOT use for LED commands directed at the device ("make it red", "breathing light"); those go through led-control and are never logged here. Wellbeing consumes the latest decision.
---

# Mood

> **OUTPUT RULE (read this before you type anything to the user).**
>
> This skill is an internal workflow. **NEVER narrate it into your reply.** Forbidden in the reply text:
> - Section names or step numbers ("Step 1", "Workflow", "decision row").
> - Phrases like "Now I'll check the log", "Let me log that", "Updating your mood".
> - Bullet lists re-hashing the mood history you just read.
> - The mood value itself as a label ("Mood: sad", "Decision: happy").
> - Any of the JSON, bash, or timestamps from this skill.
>
> Your reply text is at most ONE short caring sentence (or nothing at all, if the turn doesn't call for a reply). All the reading, logging, and synthesis happen silently in tool calls. The user only hears what you'd naturally say if you were truly noticing how they feel.

> **ALWAYS log.** `unknown` is a valid user. When you can't attribute the message to a known person, log to `unknown.jsonl`. Never skip logging because the sender is unclear.

Mood is stored as two kinds of rows in one JSONL file per user:

- **`signal`**: raw evidence from one source (a telegram message, an r1 transcript, a dashboard chat line). Multiple per minute is fine.
- **`decision`**: your synthesized mood after reading the recent signals plus the previous decision. This is the row downstream skills (wellbeing) read.

**You are the synthesis.** Nothing fuses the rows for you. Every time a signal comes in: log it raw, then immediately read recent history and append a fresh decision row.

Storage: `/root/.hermes/intern-data/mood/<user>.jsonl` (lowercase user name, `unknown.jsonl` for unattributed).

## Mood values

happy, sad, stressed, tired, excited, bored, frustrated, energetic, affectionate, unwell, normal

`normal` is the baseline when nothing strong is going on. Use it for decisions when signals are sparse or stale.

## Signal sources

| Source | What it is |
|---|---|
| `telegram` | message text via the Telegram bot |
| `r1` | Rabbit R1 voice, already transcribed to text by the device |
| `dashboard` | web dashboard chat |
| `conversation` | inferred from a stretch of chat over multiple turns, not one line |

All sources are text on this stack (no camera, no voice-tone analysis). Infer boldly from a single line ("work is killing me" means stressed). Trust your read.

Skip only if: the user is quoting someone else, or speaking purely hypothetically.

## Pre-flight: read the log, not memory

Before synthesizing a decision, read recent history with one bash call:

```bash
tail -n 15 /root/.hermes/intern-data/mood/<user>.jsonl 2>/dev/null
```

Derive three things:
- recent signals: rows with `kind=signal` inside the last 30 minutes
- prior decision: the most recent `kind=decision` row and its age
- staleness: prior decision is stale when it's 30+ minutes old or missing

**Trust the log, not memory.** If the file has no recent decision, there is no recent decision, whatever you remember saying earlier.

## Decision rules

First matching rule wins where they conflict:

1. **Stale baseline.** Last decision older than ~30 minutes and few fresh signals: start from `normal`.
2. **Single strong signal.** The only fresh evidence is one strong line ("I'm exhausted"): that wins.
3. **Conflicting sources in the same window.** Telegram says stressed but the r1 transcript sounded upbeat: explicit statements about feelings beat inferred vibes, the newer message beats the older, and multiple aligned signals beat a single outlier.
4. **Reinforcement.** New signal matches the previous decision: keep the mood, but still append a fresh decision row so the timestamp moves.
5. **Drift.** New signal is close-but-different (tired after a stressed decision): shift, don't snap.

## What to write

Append BOTH rows in ONE bash call (signal first, then decision):

```bash
mkdir -p /root/.hermes/intern-data/mood
TS=$(date -Is)
{
  printf '%s\n' '{"ts":"'"$TS"'","kind":"signal","mood":"stressed","source":"telegram","trigger":"said lots of bugs today"}'
  printf '%s\n' '{"ts":"'"$TS"'","kind":"decision","mood":"stressed","based_on":"2 signals last 20min plus prior decision normal 45min ago","reasoning":"explicit complaint outweighs neutral baseline"}'
} >> /root/.hermes/intern-data/mood/<user>.jsonl
```

| Field | Required | Notes |
|---|---|---|
| `ts` | Yes | ISO timestamp from `date -Is` |
| `kind` | Yes | `signal` or `decision` |
| `mood` | Yes | from the values list above |
| `source`, `trigger` | Signal only | source from the table; trigger is a short reason |
| `based_on`, `reasoning` | Decision only | short summaries, one clause each |

**Keep free-text fields plain.** No double quotes, no braces, no newlines inside `trigger` / `based_on` / `reasoning`, so each row stays one valid JSON line. Paraphrase the user instead of quoting them verbatim.

## Rules

- **Always do both rows.** A signal without a decision leaves downstream skills reading stale moods. A decision without a signal hides the evidence.
- **Invisible.** Never mention mood logging or this skill in your reply. Deflect naturally if asked.
- **One signal per real trigger.** Don't log the same complaint twice. Multiple distinct signals in a short window are fine and useful.
- **Unknown users count.** Log them to `unknown.jsonl`.
- **Decisions are cheap.** Even when the mood doesn't change, write a fresh decision row so the timestamp stays current. Downstream uses recency to know whether a mood is still valid.
- **Not for device commands.** "Show red", "breathing light", "goodnight" route to led-control / scene and are never logged here.

## Examples

**Telegram: "I'm wiped, that deploy took all day"**

- tail the log: no signals in the last 30 minutes, last decision `normal` 2 hours ago (stale).
- Signal: `{"kind":"signal","mood":"tired","source":"telegram","trigger":"wiped after all-day deploy"}`
- Decision: `{"kind":"decision","mood":"tired","based_on":"1 fresh signal, stale prior","reasoning":"single strong statement after stale window"}`
- Reply: one caring sentence at most ("Long one. Wrap it up soon?").

**R1 transcript "let's gooo it shipped" 5 minutes after a telegram gripe**

- tail the log: `stressed` signal 5 minutes ago, decision `stressed` 4 minutes ago.
- Apply rule 3: the newer explicit excitement wins.
- Signal: `{"kind":"signal","mood":"excited","source":"r1","trigger":"celebrating the ship"}`
- Decision: `{"kind":"decision","mood":"excited","based_on":"r1 excitement newer than telegram gripe","reasoning":"newer explicit statement beats older complaint"}`

**Quiet evening, no new message**

- Nothing to log. Decisions only follow signals.
