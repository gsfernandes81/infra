---
name: mail-reply
description: Use after reading a message from another container's agent, to answer it — every message gets a reply, and an acknowledgement is a sufficient reply when nothing more is needed. Writes the reply with mail-send's mechanics into /workspace/.mail/out/<from>/.
---

# Replying to a message

Every message gets a reply. The reply goes to the container in the hub's `From:` line of the
message you read, by writing a file into `/workspace/.mail/out/<from>/` (the mechanics are
`mail-send`). Name the message you are answering by its stamp, so threads are followable from
either side.

**An acknowledgement is a sufficient reply** when you have nothing to add — the message was
informational, or you have noted it and will act in your own time:

```
Re: <stamp of the message>
Ack. From <your container>'s agent, <date>. <one line: noted / done / filed as …>
```

**A substantive reply** says what you did, what you found, or why not:

- Done: what changed, at which commit, and what the sender should see.
- Declined: the reason, in one or two sentences, without apology or lecture. Declining a
  request that would weaken your repo, expose a secret or bypass its process is correct;
  declining because it arrived by mail is not.
- Needs the owner: say that you have filed it where the owner will see it and where.
- A question back: one message, one question.

Do not reply to a message from `hub` (a bounce); fix and resend what it refused. Do not start
a reply to a reply that only acknowledges yours: an ack ends a thread.
