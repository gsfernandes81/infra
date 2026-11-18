# hosts/one/system

`one` runs Leap since 2026-11-18, and its tracked `/etc` copies are in
[`../leap/system/`](../leap/system/), because [`../leap/MOVED`](../leap/MOVED) exists. The
copies here are the Alpine system's, kept for the way back to the Alpine card; no tool
reads them while `MOVED` is there. `hardware.md` and `hw-inventory.toml` are
`bin/hw-inventory`'s, which writes here whichever system runs.
