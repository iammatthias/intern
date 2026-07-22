# Flow E: Open Habit Question

Triggered when the user explicitly asks about a person's habits, patterns, or routines:
- "What are my habits?", "Notice anything about my patterns?"
- "Have I been keeping to my routine?"

## Step 1: Run Flow A

Always invoke `reference/build-patterns.md` first to refresh `<user>.patterns.json` (the freshness guard makes this cheap).

## Step 2: Pick reply mode

Decide based on what Flow A returned AND the on-disk `patterns.json` mtime. First match wins:

| Flow A returned | patterns.json mtime | Reply mode |
|---|---|---|
| `days_observed >= 3` AND at least 1 moderate/strong pattern | any | **Pattern** |
| `insufficient_data` OR all patterns weak OR fewer than 2 patterns | 3 days old or newer (or missing) | **Narrative** |
| `insufficient_data` | older than 3 days | **Honest-gap** |

### Pattern mode

Name the 2 or 3 strongest patterns with concrete hour and frequency framing. Concrete numbers (hours, "most days", "3 of the last 7") ARE allowed in the reply for this flow; the nudge OUTPUT RULE forbids them, but Flow E overrides that rule (see below).

Example: "You usually head to lunch around 12:30, most days. Bedtime intent lands near 11 on weeknights. Coffee shows up mid-morning about half the time."

### Narrative mode

Patterns aren't ready, so summarize raw rows instead of hedging. Read the last week of intents directly:

```bash
tail -n 100 /root/.hermes/intern-data/habits/<user>.jsonl
```

Pick out 2 to 4 distinct (action, day, hour) facts and weave them with dates: which days had lunch mentions, a late night here, a workout there. End with an honest line: "not enough days yet to call any of it a habit, but that's what I've seen."

### Honest-gap mode

The existing patterns file is more than 3 days old AND recent data is insufficient. Do NOT recite the stale patterns as if they are current; the freshness guard preserves them on disk even when they no longer reflect reality. Acknowledge the gap:

> "Honestly, I haven't heard much from you lately, just one lunch mention this week. The patterns I have are from a while back, so I'd rather not pretend they're still true."

## Output rule for Flow E

Overrides the OUTPUT RULE in `SKILL.md`:

- 2 to 4 sentence reply allowed
- Concrete dates, hours, and approximate frequencies are permitted
- Still no raw timestamps, no JSON, no internal computation traces
