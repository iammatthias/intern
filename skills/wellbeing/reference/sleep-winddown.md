# Sleep wind-down route

Fires only when the decision table in `SKILL.md` picks `sleep-winddown` (row 3: hour 21 or later, no `sleep_winddown` row today, user active within the last ~90 minutes). Otherwise STOP.

## Intent

Late evening: gently suggest winding down for sleep. Don't moralize, don't say "you should sleep", just plant the seed. The recent-activity condition matters: with no sensors, a recent message is the only proof the user is awake, and pinging someone who's already in bed is the failure mode.

## Phrasing rules

- **1 to 3 sentences**, soft, low-energy. The later it is, the shorter and quieter the line. After 23h, one short sentence is plenty.
- Acknowledge the late hour without scolding.
- **No work-related ask.** Don't suggest stretching to keep going. The point is "wrap up", not "reset".
- **Optional health/comfort aside** (one short clause): "or tomorrow morning's going to bite", "so you wake up actually rested". At most one per night, never the same line two nights in a row.
- Match the user's language.
- Paraphrase every night; never send a template verbatim.

## Tone table (reference only, paraphrase, never copy)

| Hour | Example tones |
|---|---|
| 21 to 22h | "Getting late. Maybe wrap things up early, tomorrow shows up earlier than you'd like." |
| 22 to 23h | "Closing in on 11. Whatever it is, it'll keep till tomorrow." |
| 23h or later | "Really late now. Call it." |

## Ledger row

After sending, append:

```bash
printf '%s\n' '{"ts":"'"$(date -Is)"'","date":"'"$(date +%F)"'","hour":'"$(date +%-H)"',"action":"sleep_winddown","notes":"<your sentence>"}' \
  >> /root/.hermes/intern-data/wellbeing/<user>.jsonl
```

This row is the once-per-night gate: row 3 sees it and stays quiet for the rest of the evening.

## Follow-up

One wind-down per night. After firing, defer to silence for the rest of the evening; don't keep nudging. If the user says they're wrapping up, you may offer the night scene (scene skill), never uninvited.
