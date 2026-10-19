# MPC USB Audio

One-click web installer (Chrome/Edge, WebUSB): an Akai MPC One / One+ in Update Mode gets MPC 3.9.1 plus an add-on
that makes it a two-way USB audio device while it runs in standalone — the computer records the MPC's main out, and
audio the computer plays to it appears on the MPC's inputs 1/2. See [CLAUDE.md](CLAUDE.md) for how it works.

Or choose **Download for USB stick**: copy the downloaded `.img` to a FAT32 stick, then use
Menu › Preferences › Info › Update › USB Drive Update. Both paths install the same MPC 3.9.1 + two-way USB audio +
SSH (root, no password). The browser builds the update from Akai's verified official download; we never host firmware.

Credits: USB gadget approach from PolyVector (TheKikGen/MPC-LiveXplore issue #55); image format and fastboot unlock
from TheKikGen/MPC-LiveXplore; xz decoder: xz-decompress (MIT) / xz-embedded (public domain).
