# Open questions

> **Stage: Planning.** Questions about LogaPe that are waiting on a decision or information from
> you, collected so they can be reviewed in one sitting. Numbers never change, and new questions
> continue from the highest number used so far. Answer by number. When a question is answered,
> record the answer in the doc that raised it, then move the question to "Answered" below with a
> one-line summary.

**Last updated:** 2026-10-12

## Syslog sink ([Planning_Syslog-Sink.md](Planning_Syslog-Sink.md) §9)

1. **Which transports belong in v1?** I recommend all three: UDP, TCP and TLS. The alternative
   is UDP and TCP first, with TLS in a follow-up. Also: are client certificates (mutual TLS,
   `-ClientCertificate`) needed now?
2. **Which message format should be the default?** I recommend RFC 5424. Choose RFC 3164 if an
   existing collector only accepts the older BSD format.
3. **Where should `-Fields` go?** I recommend the message body by default, with RFC 5424
   structured data only when `-StructuredDataId` is given. Structured data needs an IANA Private
   Enterprise Number in its SD-ID. Do you have one to use as the default?
4. **What should the message body contain?** I recommend only the message and fields, because
   the syslog header already carries the timestamp and severity. The alternative is the fully
   formatted line with LogaPe's timestamp and level prefix, the same as the Event Log sink sends.
5. **Which delivery model?** I recommend synchronous sends with short timeouts and a backoff
   after failures. The alternative is a background queue from the start, which hides network
   latency but needs a flush on exit and can lose messages.
6. **Which facility should be the default?** I recommend `user`. Choose one of
   `local0`–`local7` if your collector routes by facility.
7. **Is there a syslog collector in the lab, and which product is it?** If there isn't one,
   should the live test set one up, for example rsyslog on the existing Linux target?

## Answered

None yet.
