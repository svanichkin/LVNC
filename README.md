# LVNC

Control another user's macOS session on the same Mac — like VNC, but local only: no
network, no TCP, no passwords.

Two users are logged in at the same time (Fast User Switching). You sit in one session
(the **controller**) and see and control the other one (the **target**) in a window.

```
 controller session                                      target session (in the background)
┌───────────────────────┐                               ┌───────────────────────────────┐
│ LVNC.app (viewer)     │◀── Unix socket ──────────────▶│ LVNC Agent.app (agent)        │
│  window, input,       │    input, frame notices,      │  ScreenCaptureKit capture,    │
│  clipboard, cursor    │    clipboard, cursor shape    │  CGEvent input injection      │
│                       │◀── shared memory (frames) ────│                               │
└───────────────────────┘                               └───────────────────────────────┘
```

Requires macOS 14 or later. Built and used on macOS 27 on Apple silicon.

## Contents

- [Where things live](#where-things-live)
- [Install](#install)
- [Use](#use)
- [How it works](#how-it-works)
- [Permissions](#permissions)
- [Updating](#updating)
- [Logs and troubleshooting](#logs-and-troubleshooting)
- [Uninstall](#uninstall)
- [Development](#development)
- [Known limitations](#known-limitations)

## Where things live

| Path | What | Owner |
|---|---|---|
| `/Applications/LVNC.app` | Viewer. Put it in the Dock. | installed by the controller |
| `/Applications/LVNC Agent.app` | Agent. Background app (no Dock icon). | installed by the controller |
| `/Applications/LVNC Agent.app/Contents/Resources/install-agent.sh` | One-time setup, run *in the target session*. | — |
| `/opt/homebrew/bin/lvnc-viewer` | Command-line wrapper for the viewer. | controller |
| `~/Library/LaunchAgents/local.lvnc.agent.plist` (target user) | Starts the agent at login, keeps it running. | target user |
| `/Users/Shared/lvnc/run/<target>.sock` | The agent's socket (directory mode `1777`). | agent |
| `/Users/Shared/lvnc/logs/agent-<target>.log` | Agent log. | agent |
| `/Users/Shared/lvnc/logs/viewer-<controller>.log` | Viewer log (when started from the Dock/Finder). | viewer |
| `$TMPDIR/LVNC-clipboard/` (each user) | Files received through the clipboard (last few copies). | each side |

Both apps live in `/Applications` so both users can run them, and the controller (an
admin) can update them without touching the target's home folder.

## Install

### 1. Build and install the apps (controller session, admin account)

```sh
scripts/install.sh
```

This builds a release, wraps the binaries into app bundles, signs them, and installs
`/Applications/LVNC.app`, `/Applications/LVNC Agent.app` and the
`/opt/homebrew/bin/lvnc-viewer` wrapper.

Sign with a stable code-signing identity so macOS keeps the apps' privacy permissions
across rebuilds (ad-hoc signatures change with every build and lose them). Put it in
`scripts/local.env`, which is git-ignored, or pass `LVNC_SIGN_IDENTITY`:

```sh
security find-identity -v -p codesigning          # pick one, copy its SHA-1
echo 'LVNC_SIGN_IDENTITY=<SHA-1>' > scripts/local.env
```

Without it the apps are signed ad-hoc.

Or download a build from **Releases** and move both apps to `/Applications`.

### 2. Set up the agent (once, in the target session)

Switch to the target user, open Terminal and run, naming the user(s) allowed to connect:

```sh
"/Applications/LVNC Agent.app/Contents/Resources/install-agent.sh" <controller>
```

This writes `~/Library/LaunchAgents/local.lvnc.agent.plist`, starts the agent and opens
the two System Settings panes where **LVNC Agent** needs permission (see
[Permissions](#permissions)). After granting them, restart the agent once:

```sh
launchctl kickstart -k gui/$(id -u)/local.lvnc.agent
```

From now on the agent starts at every login of the target user and is restarted if it
exits.

## Use

Open **LVNC** (Dock, Spotlight, Launchpad). Without arguments it finds the other user's
agent socket by itself; if several users run an agent it asks which one. From a terminal:

```sh
lvnc-viewer <target>                 # by user name
lvnc-viewer --socket <path>          # explicit socket
```

In the window:

- **Keyboard:** while the window is focused, *all* keys go to the target session,
  including ⌘-combinations (⌘Q, ⌘W, ⌘Tab is the only exception, it stays with the system).
  Close the window with the mouse, or use the menu bar: **LVNC → «Выйти из LVNC»** (Quit;
  the viewer's UI is in Russian).
- **Keyboard layout:** the target always uses the input source selected on your side,
  including switches made by Karabiner or ⌃Space and Japanese input methods.
- **Mouse and scrolling** work as usual. Your own cursor takes the shape of the target's
  cursor (I-beam, pointing hand, resize arrows), so there is no pointer lag.
- **Clipboard:** copy on one side, paste on the other — text, rich text, HTML, images, and
  files or folders copied in Finder.
- **Hazard stripes** (yellow/black) on the left and right edges mark the window as the
  remote screen. In full screen they fill the bars beside the image.
- **Full screen:** the green button. The image keeps its proportions.

## How it works

### Transport and authentication

The agent listens on a Unix socket in `/Users/Shared/lvnc/run`. When a process connects,
the agent asks the kernel who it is (`getpeereid`) and accepts only uids listed with
`--allow`. There are no passwords and nothing listens on TCP.

### Frames: shared memory

At startup the agent creates an anonymous POSIX shared memory region (`shm_open` with
mode `0600`, immediately unlinked, so nobody can open it by name). It holds a header page
and three BGRA frame buffers. The region's file descriptor is handed to the viewer over
the authenticated socket (`SCM_RIGHTS`), so only the agent and the viewer can map it.

The agent compares every captured frame with the previous one in 64×64 tiles. Changed
tiles accumulate until a buffer is free; then only those tiles are copied into it and the
viewer gets a short message: *buffer N, these rectangles changed*. The viewer copies the
rectangles into its own image, releases the buffer and redraws. A slow viewer simply gets
fewer, larger updates — never stale pixels.

Both sides do the pixel work on the GPU (Metal), the CPU only bookkeeps:

- **Agent:** the captured frame (an IOSurface) becomes a texture without a copy; a compute
  kernel compares it with the previous frame, kept on the GPU, and flags changed tiles; blits
  copy those tiles straight into the shared memory, which Metal sees as a no-copy buffer.
- **Viewer:** the screen is four IOSurfaces that CoreAnimation shows directly. Blits copy the
  changed rectangles from shared memory into the next surface (never the one on screen or
  the one before it, which the render server may still read); each surface first catches up
  on areas that changed since it was last written.

Without Metal (or for frames that are not IOSurfaces) both fall back to CPU copies.
Scrolling at ~50 fps costs about 5% of one core in the agent and 3% in the viewer on an
M3; a static screen costs nothing (ScreenCaptureKit sends no frames, the agent skips idle
ones). The capture rate is capped at the refresh rate of the screen the viewer is on.

### Capture: ScreenCaptureKit

The agent captures the target's display with a ScreenCaptureKit stream (30 fps by
default). If the stream dies — it can when the session is moved to the background — the
agent falls back to polling single frames with `SCScreenshotManager`, which keeps working
in a background session.

Capture follows what the viewer can show:

| Viewer window | Capture |
|---|---|
| focused | full rate |
| visible, focus elsewhere | 2 fps |
| hidden (minimized, covered, other Space, app hidden) or closed | stopped |

### Input

The viewer sends physical macOS key codes with modifier flags, mouse positions normalized
to the image (0…1), button/click counts and pixel scroll deltas. The agent turns them into
`CGEvent`s posted into its own session. Because key codes are physical, the target's
selected input source decides which characters they produce — which is why the viewer
mirrors its input source to the agent (`TISSelectInputSource` on the target side).

When the viewer disconnects or loses focus, everything it held down is released, so no
key or button gets stuck.

### Cursor

Frames are captured *without* the cursor. The agent watches the target's cursor shape
(`NSCursor.currentSystem`) and sends it (PNG + hot spot) whenever it changes; the viewer
uses it as its own cursor over the image. Pass `--draw-cursor` to the agent to draw the
cursor into the frames instead.

### Clipboard

Both sides poll the pasteboard's change count every 0.5 s and send changes to the peer:

- text, RTF, HTML, PNG and TIFF are sent as data (up to 64 MB);
- **files and folders** copied in Finder are not read at all: the sender opens them and
  passes the open file descriptors (`SCM_RIGHTS`, up to 128 files per copy). The receiver
  clones them with `fclonefileat` into its own `$TMPDIR/LVNC-clipboard/…` — instant and
  space-free on APFS, private to the receiving user — and puts file URLs on its
  pasteboard. A single image file is also offered as image data, so pasting into an
  image-aware app inserts the picture;
- items that password managers mark as concealed or transient
  ([nspasteboard.org](http://nspasteboard.org) types) never leave the session;
- the same content is never sent twice, and received content is not echoed back.

### Updates without restarts

Both apps watch their own executable. When `scripts/install.sh` replaces it:

- the agent (running under launchd) exits within ~5 s and launchd starts the new build;
- the viewer relaunches itself within ~3 s.

When the connection drops, the viewer retries quietly for up to 20 s (also covering a
protocol version mismatch while one side is still updating) before showing an alert.

## Permissions

In the **target** session, **LVNC Agent** needs:

| System Settings → Privacy & Security | Why |
|---|---|
| Screen & System Audio Recording → Screen Recording | capture the screen |
| Accessibility | post keyboard and mouse events |

Grant them, then restart the agent (`launchctl kickstart -k gui/$(id -u)/local.lvnc.agent`).
The viewer needs no special permissions.

Thanks to the stable signature these grants survive updates. If the signing identity
changes, macOS treats the app as new and they have to be granted again.

## Logs and troubleshooting

```sh
tail -f /Users/Shared/lvnc/logs/agent-<target>.log
tail -f /Users/Shared/lvnc/logs/viewer-<controller>.log
```

Both print their version and build time at startup. Useful agent lines:

- `ready on …, allowed: …` — listening;
- `viewer connected` / `viewer is active|background|hidden` — session and capture state;
- `stream started` / `stream stopped … -> snapshots` — capture mode;
- `[publish] 28.6 updates/s, avg 14 of 1040 tiles per update` — every 10 s while streaming;
- `input source: selected …`, `[cursor] shape …`, `clipboard to/from peer: …`.

| Symptom | Check |
|---|---|
| «Агент LVNC не найден» (agent not found) | Is the agent running in the target session? `launchctl print gui/<target uid>/local.lvnc.agent` (as the target), or look at the agent log. |
| Connection refused / closed right away | Is your user in `--allow`? The agent logs `rejected connection from uid …`. |
| Black or frozen image | Screen Recording permission for LVNC Agent; restart the agent after granting it. |
| Mouse/keyboard do nothing | Accessibility permission for LVNC Agent. |
| Wrong characters | The input source you use must be installed for the target user; the agent log says if it is not. |

Agent options (edit `ProgramArguments` in the LaunchAgent plist):

```
--allow <users>     users allowed to connect (required)
--socket <path>     socket path (default /Users/Shared/lvnc/run/<user>.sock)
--fps <n>           stream frame rate (default 30)
--snapshot          always poll snapshots instead of streaming
--snapshot-fps <n>  snapshot rate (default 15)
--scale <x>         capture scale vs. display points (default: native pixels)
--view-only         never inject input
--no-clipboard      do not share the clipboard
--draw-cursor       draw the cursor into frames instead of sending its shape
--test-pattern      synthetic frames, no capture, no input (for testing)
```

## Uninstall

In the target session:

```sh
"/Applications/LVNC Agent.app/Contents/Resources/install-agent.sh" --uninstall
```

Then, as an admin:

```sh
rm -rf "/Applications/LVNC.app" "/Applications/LVNC Agent.app" /opt/homebrew/bin/lvnc-viewer
rm -rf /Users/Shared/lvnc
```

Remove **LVNC Agent** from the Privacy & Security lists if you like.

## Development

```
Sources/
  CLVNC/          C helpers Swift cannot express: shm_open, SCM_RIGHTS, sockaddr_un, fclonefileat
  LVNCCore/       wire protocol, socket connection, shared memory, clipboard sync, input sources
  lvnc-agent/     capture (ScreenCaptureKit), frame publisher (tile diff), input, cursor watcher
  lvnc-viewer/    AppKit window, remote view, hazard stripes, reconnect and update logic
Tests/LVNCCoreTests/   protocol, descriptor passing, clipboard (on private pasteboards), input sources
scripts/
  bundle.sh           build and sign the two app bundles (used by install.sh and CI)
  install.sh          bundle and install into /Applications
  install-agent.sh    LaunchAgent setup for the target session
  make-icon.swift     renders the app icon
third_party/macVNC/   earlier approach, see below
.github/workflows/    CI (build + tests); a v* tag builds, signs, notarizes and publishes a release
```

```sh
swift build            # debug build
swift test             # tests; they never touch the real clipboard or input source
scripts/install.sh     # release build into /Applications
```

The whole pipeline can be tried in one session without any permissions:

```sh
.build/debug/lvnc-agent --allow $USER --test-pattern --no-clipboard \
    --socket /Users/Shared/lvnc/run/test.sock &
.build/debug/lvnc-viewer --socket /Users/Shared/lvnc/run/test.sock
```

(Unix socket paths are limited to 104 bytes, so keep test sockets in a short directory.)

### third_party/macVNC

The first working version: LibVNC's macVNC, patched to survive Fast User Switching
(snapshot fallback, loopback-only listening, no IPv6 clash with Apple's Screen Sharing).
It works with any VNC client over `127.0.0.1`. See `third_party/macVNC/UPSTREAM.md`.
Apple's own Screen Sharing cannot be used for this: it refuses to connect to the same Mac,
even through an SSH tunnel.

## Known limitations

- **Sound** is not forwarded. A background session's sound plays directly on the Mac's
  speakers — except Safari, which mutes itself while its session is inactive.
- **⌘Tab** and other system-level shortcuts stay with the controller's session.
- **One viewer at a time:** a new connection replaces the previous one.
- **One display:** the agent captures the target's main display.
- **Clipboard folders** with more than 128 files are not sent; symlinks inside copied
  folders are skipped.
- **Full screen** on a Mac with a camera notch: macOS places the window below the notch,
  so the image is slightly smaller than the display and the sides show the hazard stripes.
