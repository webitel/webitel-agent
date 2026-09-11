# Windows Installation Troubleshooting

Use this guide when the app **installs / launches on some machines but not
others**. The app is signed with our code-signing certificate, so no certificate
import is needed.

> The Windows build captures the screen and audio **in-process** via native
> WebRTC — there is **no `ffmpeg.exe`** on Windows. So the things that break an
> install/launch are missing **runtimes** and **antivirus**, not a bundled
> helper binary.

The usual culprits, in order:

1. **Missing Microsoft Edge WebView2 Runtime** — login window is blank / app
   won't get past sign-in.
2. **Missing Visual C++ Redistributable** — app won't launch at all
   (missing-DLL error).
3. **Antivirus / EDR** quarantining the installer or `webitel_desk_track.exe`.
4. **SmartScreen / AppLocker / WDAC / MSIX sideloading** policy.

> Commands below run in an **elevated** PowerShell (Run as administrator).

---

## 1. Microsoft Edge WebView2 Runtime (most common)

The login screen is a webview. On Windows it is rendered by the **Edge WebView2
Runtime**. Windows 11 and up-to-date Windows 10 already have it; locked-down or
older Windows 10 machines often **don't** — that is the classic "works on my PC,
blank window on theirs".

Check if it's installed:

```powershell
Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
```

If nothing is returned, install the **Evergreen WebView2 Runtime** (free, from
Microsoft): <https://developer.microsoft.com/microsoft-edge/webview2/> → "Evergreen
Standalone Installer" (x64). For fleet rollout, push it via Intune / SCCM.

Symptom when missing: app installs and starts, but the login window is white /
empty and never reaches the Webitel auth page.

---

## 2. Visual C++ Redistributable

The native WebRTC / plugin DLLs need the **Microsoft Visual C++ 2015–2022
Redistributable (x64)**. Without it the app fails to start with a
`VCRUNTIME140.dll` / `MSVCP140.dll` missing error.

Install: **Microsoft Visual C++ Redistributable (x64)** —
<https://aka.ms/vs/17/release/vc_redist.x64.exe>

Symptom when missing: the app doesn't open at all; Windows shows a missing-DLL
dialog on launch.

---

## 3. Antivirus / EDR

A screen + audio recorder trips heuristic AV / EDR (Kaspersky, Symantec, ESET,
CrowdStrike, etc.), which may quarantine the installer or the main executable.
When that happens the app either won't install or is removed shortly after.

Add exclusions for the process and folders:

**Process:** `webitel_desk_track.exe`

**Folders:**

```
C:\Program Files\webitel_desk_track\              (MSI install location)
%APPDATA%\com.example\webitel_desk_track\         (runtime data: config.json, logs)
```

**Microsoft Defender example** (adapt for your AV console):

```powershell
Add-MpPreference -ExclusionProcess "webitel_desk_track.exe"
Add-MpPreference -ExclusionPath "C:\Program Files\webitel_desk_track"
Add-MpPreference -ExclusionPath "$env:APPDATA\com.example\webitel_desk_track"
```

For centrally-managed AV (Kaspersky Security Center, Symantec, etc.), push the
same exclusions from the management console.

---

## 4. SmartScreen / AppLocker / MSIX sideloading

- **SmartScreen** ("Windows protected your PC"): **More info → Run anyway**, or
  `Unblock-File "C:\path\webitel_desk_track.msi"`. For fleet rollout, deploy via
  Intune / SCCM / GPO so it comes from a trusted channel.
- **AppLocker / WDAC** (application whitelisting on managed machines): allow-list
  `webitel_desk_track.exe` by publisher (our signing cert) or by path.
- **MSIX on Windows 10**: enable sideloading —
  `Settings → Update & Security → For developers → Sideload apps`, or the GPO
  `Allow all trusted apps to install = Enabled`. Windows 11 installs signed MSIX
  without this.

---

## About the firewall

The firewall does **not** block installation — a local MSI/MSIX install needs no
network. The firewall only matters **after** install, for the app to connect and
stream: outbound `443/TCP` (WebSocket + API) and, for screen share over VPN,
TURN on `3478` UDP/TCP. If the app installs and logs in but the supervisor sees a
black screen, that's a network/TURN issue, not an install one.

---

## Verification

On the target machine, confirm:

- [ ] App installs without error and `webitel_desk_track.exe` runs
      (Task Manager → Details).
- [ ] The login window shows the real Webitel auth page (not blank) → WebView2 OK.
- [ ] No missing-DLL dialog on launch → VC++ redist OK.
- [ ] The executable is not quarantined by AV.

If it still fails, collect the app log from
`%APPDATA%\com.example\webitel_desk_track\logs\` — the startup lines show how far
it got.
