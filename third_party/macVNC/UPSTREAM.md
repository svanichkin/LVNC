# Upstream

Vendored from https://github.com/LibVNC/macVNC at commit 6c45640
("README: mention that password is needed for MacOS built-in client").

## LVNC patches

- Capture survives Fast User Switching: when the SCStream fails, fall back to
  polling SCScreenshotManager snapshots instead of exiting (`-snapshot`, `-fps`).
- Row-by-row frame copy with bounds checks.
- Listen on IPv4 loopback only by default; IPv6 disabled unless `-rfbportv6`/`-listenv6` given.
- Print version and `Ready: vnc://...` on startup.
