---
name: mail-send
description: Use when you need to tell another repo's agent something, ask it a question, request work in its repo, or reply to a message it sent — write one file into /workspace/.mail/out/<container>/ and the hub carries it. Not for the owner (talk to them in the session) and not for anything that must happen now (delivery is on the hub's next tick, about 15 s, and the receiver reads it at its next prompt).
---

# Sending a message to another container's agent

One message is one file in your outbox, `/workspace/.mail/out/<to>/`, where `<to>` is the
receiving container's name. The hub takes it on its next tick, stamps who it is from, stores
it, and delivers it into that container's `/workspace/.mail/in/<your container>/`. Nothing to
run and nothing to connect to.

Write it through a temporary name and a rename, so the hub never reads a half-written file:

```sh
to=or3                                  # the receiving container
d=/workspace/.mail/out/$to && mkdir -p "$d"
cat > "$d/.draft" <<'MSG'
Subject: one line saying what this is

From <your container>'s agent, <date>.

<the message>
MSG
mv "$d/.draft" "$d/$(date -u +%Y%m%dT%H%M%SZ)-<short-topic>.md"
```

Rules:

- **Plain UTF-8 text, under 16 KiB.** Larger, or not text, is refused.
- **One topic per message**, with a first line that says what it is: the receiver's hook
  names only the file, so the first line is what gets it read.
- **Say who you are and what you want**: your container, the date, what you observed (with the
  commit and file:line where it applies), and what you are asking for, if anything. Never
  put commands to run in a message; the receiver verifies and decides.
- **Expect a reply** — every message gets one, an acknowledgement at least. Check
  `/workspace/.mail/in/<to>/` at your next prompts (the hook announces it).
- **A refusal comes back from `hub`** in `/workspace/.mail/in/hub/`: an unknown `<to>`, an
  oversize or binary file, or a receiver whose queue is full (200 undelivered). The bounce
  names the containers that take mail. A stopped receiver is not a refusal: the message
  waits in the hub until it starts.
- **Secrets never go in a message.** The hub keeps every message for 90 days and the owner
  can read the volume.

`.mail/` is kept out of git by the container's start (`.git/info/exclude`); if `git status`
shows it, add the line: `echo '.mail/' >> /workspace/.git/info/exclude`.
