# Morning greeting route

Fires only when the decision table in `SKILL.md` picks `morning-greeting` (row 2: hour in [5, 11), no `morning_greeting` row today, first contact of the day or the morning cron tick). Otherwise STOP.

## Intent

First contact of the day: greet warmly and ask one open question about the day's plan. Sets a relational tone without lecturing.

## Phrasing rules

- **1 to 3 sentences**, warm and casual, like saying hi when someone walks into the kitchen. A short "Morning, what's on today?" is fine; a slightly longer riff is fine when the moment has texture (weekend, slow start).
- **One open-ended question** about today's plan, intent, or mood. Avoid yes/no.
- Don't comment on lateness or how long they've been quiet; that's not the spirit.
- **Optional gentle aside** (one short clause): "grab some water before you dive in", "hope it's a smooth one". At most one per morning, never the same line two days in a row.
- Match the user's language; mirror recent chat history.
- Paraphrase every day; never send a template verbatim.

## Tone table (reference only, paraphrase, never copy)

| Sub-mood | Example tones |
|---|---|
| neutral / fresh | "Morning, what's on the docket today?" / "Morning. What are you tackling first?" |
| weekend feel (Sat/Sun) | "Weekend morning. Slowing it down, or still on the grind?" |
| late morning (9h or later) | "Slow start today. What's the one thing you want to knock out first?" |

## Ledger row

After sending, append (same shape as `SKILL.md`, one bash call):

```bash
printf '%s\n' '{"ts":"'"$(date -Is)"'","date":"'"$(date +%F)"'","hour":'"$(date +%-H)"',"action":"morning_greeting","notes":"<your sentence>"}' \
  >> /root/.hermes/intern-data/wellbeing/<user>.jsonl
```

This row is the once-per-day gate: row 2 sees it and skips for the rest of the day.

## Follow-up

One greeting per day. If the user answers, that's a regular conversation, not gated by this skill. If they don't reply, stay silent until tomorrow.
