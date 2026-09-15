# Net Doctor

A portable, single-file **network troubleshooter *and* auto-fixer** for Windows.
Copy `NetDoctor.exe` to a USB stick, plug it into any Windows 10/11 PC, run it, and get a
full engineer-style checkup of **every connection** (wired Ethernet, Wi-Fi, and virtual/VPN) —
then a **plain-language report** of what is going on and **click-by-click steps** to fix it.
Optionally let it **auto-repair** what it can, logging every change. No installation required.

## Portability — what to put on the USB

**Copy only `NetDoctor.exe`.** That single file *is* the whole program — the PowerShell
code is compiled and embedded inside it. It does **not** need `NetDoctor.ps1`, this repo,
the ps2exe tool, or anything in `Program Files`. It only uses networking features built
into every Windows 10/11, so it runs on any normal Windows PC with nothing installed.

(`NetDoctor.ps1` is just the human-readable source, kept for editing/rebuilding.)

## How to use

1. Copy **`NetDoctor.exe`** onto your USB stick.
2. **Diagnose:** double-click `NetDoctor.exe`. The window stays open until you press a key.
3. Read **WHAT IS GOING ON** (everyday language) and **HOW TO FIX IT** (numbered clicks in
   Windows Settings). The technical notes underneath are for IT or for sending to someone.
4. **Fix:** run it with **`-Fix`** to auto-repair what it can. It will request Administrator
   rights (a Windows UAC prompt) automatically, since changing network settings needs admin.
   - **Preview first (safe):** `NetDoctor.exe -Fix -DryRun` shows *exactly* what it would change
     without changing anything.
5. A full **text report is saved next to the exe** (on the USB): `NetDoctor-report-<PC>-<date>.txt`.
   When fixes are applied, changes are also appended to **`NetDoctor-fixlog.txt`** (a running
   history, with an `undo:` command for each change).

> First run from a USB may trigger Windows SmartScreen ("unknown publisher").
> Click **More info → Run anyway** — normal for unsigned tools.

## Options

```
NetDoctor.exe                 Diagnose only (default). Saves a report.
NetDoctor.exe -Fix            Diagnose, then auto-fix safe issues (asks for admin).
NetDoctor.exe -Fix -DryRun    Preview fixes; change nothing (no admin needed).
NetDoctor.exe -DeepFix        Also allow deeper fixes that may require a reboot.
NetDoctor.exe -Quick          Skip slow tests (throughput, traceroute, MTU, Wi-Fi scan).
NetDoctor.exe -NoColor        Plain text (good for piping/logging).
NetDoctor.exe -NoReport       Don't write the report file.
NetDoctor.exe -NoPause        Don't wait for a keypress at the end.
NetDoctor.exe -PingCount 40   More samples = more accurate loss/jitter.
```

## What it checks (full flow)

| # | Stage | Detects |
|---|-------|---------|
| 1 | This computer | OS, uptime, airplane mode, power plan |
| 2 | Every connection | **All adapters**: wired, Wi-Fi, VPN/virtual — Up / disconnected / disabled |
| 3 | Wired Ethernet | Cable unplugged, link speed, duplex, energy-efficient Ethernet, IPv4 binding |
| 4 | Wi-Fi | SSID, band, channel, RSSI, encryption, **nearby 2.4 vs 5 GHz**, co-channel congestion |
| 5 | Windows services | DHCP / DNS / WLAN services, NCSI “has internet?” icon, IP-conflict events |
| 6 | Addresses | IPv4, **APIPA vs DHCP vs static**, lease, DNS list, **which adapter Windows actually uses** |
| 7 | Home box (LAN) | Gateway ping **and ARP/neighbor**, router web ports, per-DNS reachability + lookup |
| 8 | Internet | Ping **and TCP 443** to Google/Cloudflare/Quad9, IPv6, loss/jitter |
| 9 | DNS | Configured resolver speed vs public resolvers (classic “slow internet” cause) |
| 10 | Path, NAT, MTU | Traceroute, **double NAT**, **CGNAT (100.64.x)**, latency jump, Path MTU |
| 11 | Web | HTTP/HTTPS, **captive portal**, **clock skew**, **proxy / PAC** |
| 12 | Security | Firewall, VPN/virtual adapters, hosts-file hijack |
| 13 | TCP tuning | Receive-window auto-tuning (throughput limiter) |
| 14 | Throughput | Single-stream download estimate (hard 12s cap) |
| 15 | Report | Connection map, **plain-language story**, **step-by-step Windows clicks**, technical notes |

Then it produces an overall verdict, a ranked issue list, and the single **most likely cause**.

## What `-Fix` can repair automatically

Each fix is **logged** (with an undo command) and only applied with admin rights:

- **Slow/broken DNS** → switch the adapter to the fastest *measured* public resolver, and flush the cache.
- **DHCP failure / APIPA / no gateway** → release & renew the DHCP lease.
- **Adapter power-saving** (causes Wi-Fi drops) → disable it on the NIC.
- **Disabled Ethernet adapter** → enable it.
- **Stopped network services** (DHCP/DNS/WLAN) → start them.
- **Dead/unwanted proxy** breaking the web → disable the WinINET proxy + reset the WinHTTP proxy.
- **Wrong system clock** (breaks HTTPS) → restart Windows Time and resync.
- **TCP auto-tuning disabled** (caps speed) → reset to `normal`.
- **Deep fixes** (`-DeepFix`, may need reboot): **Winsock / TCP-IP stack reset** when web fails
  despite working IP + DNS.

Things it **can't** fix in software (router/physical) are reported with **click-by-click**
guidance instead — e.g. weak Wi-Fi, 2.4 GHz channel choice, a stacked extra router (double NAT),
ISP-side latency, or an empty Ethernet port.

## Rebuilding the .exe

The logic lives in `NetDoctor.ps1`. To recompile after edits:

```powershell
Install-Module ps2exe -Scope CurrentUser        # one time
Import-Module ps2exe
Invoke-ps2exe .\NetDoctor.ps1 .\NetDoctor.exe -Title "Net Doctor" -Version 3.1.0
```
