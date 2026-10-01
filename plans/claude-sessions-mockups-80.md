# claude-sessions — the mockups at 80 columns

The approval gate is the 40-column set, inline in
[`claude-sessions.md`](claude-sessions.md) under `## Mockups`; the owner reads on a phone,
where these would wrap. This file is the same screens drawn at 80 so the desktop case is
on the record too. Both are generated to width, not typed.

What 80 columns changes: nothing structural. The title field grows from 29 to 69
characters, so fewer titles are truncated, and the hint line fits on one line instead of
two. The marks, the order and the keys are identical.

### Mockup 1 — The list, every mark mixed
```
infra-dev · 6 open · 812M of 1.0G
────────────────────────────────────────────────────────────────────────────────
1 !   permission: write hosts/one                                             2m
2 *   retire the old tunnel                                                  14m
3 *t  loop: watch the base build                                             31m
4 @   immich upgrade                                                         now
5 z   mount guards on one                                                     2d
6 u   claude                                                                  5h
────────────────────────────────────────────────────────────────────────────────
↵ open   n new   c close   ? keys   s shell   q quit
```

### Mockup 2 — Nothing open
```
infra-dev · nothing open · 812M of 1.0G
────────────────────────────────────────────────────────────────────────────────

  No claude session in this container.

  n   start one in /workspace
  q   a shell instead

────────────────────────────────────────────────────────────────────────────────
n new   ? keys   s shell   q quit
```

### Mockup 3 — Closing a live slot
```
infra-dev · 6 open · 812M of 1.0G
────────────────────────────────────────────────────────────────────────────────
1 !   permission: write hosts/one                                             2m
2 *   retire the old tunnel                                                  14m
╭──────────────────────────────────────────────────────────────────────────────╮
│ Close slot 2?                                                                │
│   retire the old tunnel                                                      │
│                                                                              │
│ Running. Stops the process, not the                                          │
│ conversation — resumable from disk.                                          │
│                                                                              │
│ y close    n keep                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
```

### Mockup 4 — No room to open another
```
╭──────────────────────────────────────────────────────────────────────────────╮
│ No room for another claude                                                   │
│                                                                              │
│ 892M of 1.0G used. A new one wants                                           │
│ about 250M.                                                                  │
│                                                                              │
│ Offload slot 5, idle 2d?                                                     │
│   mount guards on one                                                        │
│   resumable from disk                                                        │
│                                                                              │
│ y offload, then open    n cancel                                             │
╰──────────────────────────────────────────────────────────────────────────────╯
```

### Mockup 5 — A resume that fails
```
╭──────────────────────────────────────────────────────────────────────────────╮
│ Slot 5 did not resume                                                        │
│                                                                              │
│ claude --resume 0f9c4a1e exited 1                                            │
│   No conversation found with that                                            │
│   session id                                                                 │
│                                                                              │
│ Left offloaded. Nothing was deleted;                                         │
│ the transcript may be gone.                                                  │
│                                                                              │
│ r retry   c close it   ↵/Esc back                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
```

### Mockup 6 — Back from a slot, after detaching
```
infra-dev · 6 open · 1.0G of 1.0G
────────────────────────────────────────────────────────────────────────────────
1 !   permission: write hosts/one                                             2m
2     retire the old tunnel                                                  now
3 *t  loop: watch the base build                                             31m
4 @   immich upgrade                                                         12m
5 z   mount guards on one                                                     2d
6 u   claude                                                                  5h
────────────────────────────────────────────────────────────────────────────────
detached from 2 · it is still running
↵ open   n new   c close   ? keys   s shell   q quit
```

### Mockup 7 — The keys, on ?
```
infra-dev · keys and marks
────────────────────────────────────────────────────────────────────────────────
↵      open the row (resume if z)
n      new session in /workspace
c      close the row
s      a shell in /workspace
q, Esc quit the launcher
?      this

!  wants you: a prompt is waiting
*  unread: it finished while away
t  a timer is pending; not
   offloaded until it fires
@  attached somewhere else too
z  offloaded: ↵ resumes it
u  not started by claude-sessions
────────────────────────────────────────────────────────────────────────────────
↵ open   n new   c close   ? keys   s shell   q quit
```

### Mockup 8 — The hint line as the terminal narrows
```
at 40 columns, the right edge marked:
========================================
↵ open   n new   c close   ? keys
s shell   q quit
at 34 columns, the right edge marked:
==================================
↵ open   n new   c close   ? keys
s shell   q quit
at 26 columns, the right edge marked:
==========================
↵ open   n new   c close
? keys   s shell   q quit
at 18 columns, the right edge marked:
==================
↵ open   n new
c close   ? keys
s shell   q quit
at 12 columns, the right edge marked:
============
↵ open
n new
c close
? keys
s shell
q quit
at 9 columns, the right edge marked:
=========
↵ open
n new
c close
? keys
s shell
q quit
at 7 columns, the right edge marked:
=======
↵ open
n new
c close
? keys
s shell
q quit
at 6 columns, the right edge marked:
======
↵ open
n new
? keys
q quit
at 5 columns, the right edge marked:
=====
  (the menu refuses to draw; the
   door execs a login shell and
   says why)
```
