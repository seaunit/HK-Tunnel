# HK-Tunnel for Android

The phone counterpart of the Windows tool in the parent folder: one SSH
connection to the same Hong Kong server, used as a **device-wide proxy**. No
root required.

> **Before you use this, check your server provider's terms.** Turning a server
> into a proxy is what cloud providers call traffic relaying (流量穿透), and the
> cheap "lightweight" / shared plans usually forbid it. Alibaba Cloud's
> lightweight plan, for one, says relaying traffic can get the instance **shut
> down and locked**, and that the advertised bandwidth is a peak rather than a
> guarantee - saturating it is itself what triggers throttling. See the parent
> [README](../README.md) for the details and the known cases.

## How it fits together

```
any app ─┐
         ├─► [VpnService tun] ─► [hev-socks5-tunnel] ─► [local SOCKS5] ─► [SSH] ─► HK server ─► internet
shell ───┘   198.18.0.1/30        (native, NDK)          127.0.0.1:1080   direct-tcpip
```

* **`VpnService`** captures all traffic; the settings screen hands it a tun
  descriptor, which is the only way to proxy the whole device without root.
* **`hev-socks5-tunnel`** (vendored under `app/src/main/jni`, sing-box's engine)
  turns IP packets from that descriptor into SOCKS5 connections.
* **`Socks5Server`** is a small loopback SOCKS5 endpoint; each `CONNECT` becomes
  an SSH `direct-tcpip` channel through **JSch**, so the server resolves names
  and makes the outbound connection.
* The app excludes itself from the tunnel (`addDisallowedApplication`), otherwise
  its own SSH socket would be routed back into itself.

### A note on DNS

SSH port forwarding is TCP-only, so UDP cannot be tunnelled. Instead the core is
configured with *mapped DNS*: DNS answers are synthesised locally as fake
addresses in `100.64.0.0/10`, and when a connection targets one of those the
core swaps it back for the original host name. The name then travels through
SSH and is resolved on the far side, so lookups never leak to the local network.

## Building

Requires JDK 17, Android SDK (platform 36), NDK 27 and CMake — Android Studio
works, as does the command line if `local.properties` points at your SDK:

```
sdk.dir=C\:\\path\\to\\Android\\Sdk
```

**On Windows, run this once after a fresh clone**, then build:

```powershell
powershell -ExecutionPolicy Bypass -File tools/materialize-symlinks.ps1
.\gradlew.bat assembleRelease
```

The vendored tree stores a number of headers as symbolic links. A Windows
checkout without symlink support turns those into one-line text files holding
the link target, and the C compiler then fails on them; the script replaces
each with a real copy.

The APK lands in `app/build/outputs/apk/release/app-release.apk` and is signed
with the debug key so it can be installed without any keystore setup.

### Versioning

`app/build/outputs/apk/...` always carries a versionCode that grows on its own:
it is the number of minutes since 2026-01-01, read from the build clock. That
way a fresh package is always accepted as an update and nothing has to be
remembered by hand. The human-facing label lives in `version.properties` and is
advanced with one command:

```
.\gradlew.bat bumpVersion
```

The app prints both the label and the build time at the top of its log when it
starts, so you can tell which package is installed.

## Installing and using

1. Copy `app-release.apk` to the phone and install it (allow installing from
   unknown sources if prompted).
2. Fill in the server address, SSH port, user, password and SOCKS port, then
   press **连接**. The system asks for VPN consent the first time.
3. Android shows a persistent notification while the tunnel is up; use its
   **断开** action or the in-app button to stop.

"记住密码" seals the password with an AndroidKeyStore key, so it can only be
read back on that device. Leave it off and the password is only held in memory
for the lifetime of the connection.

## Known limits

### When the SSH connection drops

The VPN is only useful while the session behind it is alive: if the SSH link dies
but the tun stays up, *every* connection on the device is captured and then
fails, and the app would still claim to be connected. The service therefore
polls the session every few seconds and, as soon as it is gone, pulls the VPN
down, says so in the app and posts a notification — the phone goes back to its
own network instead of silently losing access.

* **UDP is not tunnelled** — an inherent property of SSH port forwarding.
  Applications that insist on QUIC or other UDP transports (some video calls,
  some games) fall back to TCP or fail; DNS is unaffected because of the mapped
  resolver above.
* **IPv6 is not tunnelled either.** The usual reason is that the server has no
  IPv6 egress, so a forwarded IPv6 connection could only ever fail. The VPN
  therefore declares IPv4 only and calls `allowFamily(AF_INET6)`, which lets
  IPv6 traffic fall through to the mobile network instead of being blocked. The
  upside is that nothing errors out; the trade-off is that IPv6 traffic leaves
  through the carrier rather than through the server. Give the server real IPv6
  egress and you can add an IPv6 address plus a `::/0` route to bring it back
  inside the tunnel.
* Apps serving their own DNS over TLS to the tunnel's DNS address will fail
  their lookup, since `198.18.0.2` is not a real host.
* The host key is trusted on first use, then pinned. If the server is
  reinstalled with a new key, clear the app's data or delete
  `files/known_hosts` before reconnecting.

## Verifying

`tools/smoke-ssh-server.py` is a throwaway SSH server that accepts password
login and any `direct-tcpip` channel and prints every forwarded destination, so
a client can be exercised end to end without touching the real server:

```bash
python tools/smoke-ssh-server.py --port 2222 --user tester --password tunnelpass
```

Point the app at `10.0.2.2:2222` from an emulator; every `[forward]` and
`[data]` line shows traffic really travelling through the tunnel.
