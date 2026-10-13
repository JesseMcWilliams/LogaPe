# Open questions

> **Stage: Planning.** Questions about LogaPe that are waiting on a decision or information from
> you, collected so they can be reviewed in one sitting. Numbers never change, and new questions
> continue from the highest number used so far. Answer by number. When a question is answered,
> record the answer in the doc that raised it, then move the question to "Answered" below with a
> one-line summary.

**Last updated:** 2026-10-12

None open. New questions continue from 8.

## Answered

All from [Archive_Planning_Syslog-Sink.md](Archive_Planning_Syslog-Sink.md) §9, answered 2026-10-12. The user
also asked for current best practice throughout (recorded in that plan's §3.2).

1. **Transports in v1:** UDP, TCP and TLS, with mutual TLS included.
2. **Default format:** RFC 5424.
3. **Fields:** in the message body; RFC 5424 structured data only with `-StructuredDataId`. No
   IANA enterprise number is available as a default.
4. **Message body:** the message and fields only, without LogaPe's timestamp and level prefix.
5. **Delivery model:** synchronous, with timeouts and backoff.
6. **Default facility:** `user`.
7. **Live testing:** the lab has no collector; deploy a VM with a collector role through LABaPe.
