---
schema: autonomous.safety.v1
light:
  max_brightness: 180        # 0-255 ceiling; the LED route clamps any higher request
  # Quiet hours lower the ceiling on real wall-clock time. 22:00-07:00 -> ring dims
  # to 40, agent-independent. Values mirror upstream intern-v2; tune here.
  quiet_hours: { start: "22:00", end: "07:00", max_brightness: 40 }
---

# SAFETY.md: Autonomous Intern v1 (community stack)

The bounds contract: `DEVICE.md` says what the body can do; this file says what it must
never do, enforced deterministically by the HAL, not by prompting the agent. v1 has no
motion and no speaker, so the only governed capability is the LED ring.

## light

Every frame is clamped to `max_brightness: 180`, and inside quiet hours (22:00-07:00)
the ceiling drops to 40 regardless of what the agent asks for.
