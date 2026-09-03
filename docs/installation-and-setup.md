# Installation and Setup Guide (Windows)

This guide walks through bringing up Webitel DeskTrack from scratch: installing
the app, providing its config, and configuring the Webitel back office so screen
recording and live monitoring are actually enabled for an agent.

Webitel DeskTrack targets **Windows only**. FFmpeg does **not** need to be
installed separately — the required binary is bundled with the app as a Flutter
asset.

---

## 1. Install the app

Install the Windows build. No additional runtime dependencies are required.

### Audio setup (required)

Correct audio capture depends on three Windows sound settings:

- **Disable Stereo Mix.** In Sound Settings → Recording, disable the
  **Stereo Mix** device. Left enabled, it double-captures system audio and
  corrupts the recorded track.
- **Disable audio ducking.** Sound Settings → Recording → Properties →
  Communications → set **"Do nothing"**. Otherwise Windows lowers other app
  audio during calls, which bleeds into the recording.

---

## 2. Provide `config.json`

The app reads its settings from a `config.json`. **We provide this file** —
it is prepared for your environment (server address, ICE servers, telemetry).
Place it in the application-support directory **before** the first launch:

```
%APPDATA%\Webitel-Agent\config.json
```

You can also swap in an updated file later without restarting via **Upload
configuration** in the system tray.

---

## 3. Configure Webitel (back office)

Screen monitoring and recording are gated by back-office settings, configured
in the Webitel admin UI. Sections 3.1 and 3.2 are the baseline required in all
cases; section 3.3 is only for automatic recording.

### 3.1. Grant the "Control agent screen" permission

The role of anyone who needs to connect to, record, view, or download an
agent's screen must hold the **Control agent screen** permission.

`Permissions → Roles → <role> → Role permissions`, then add:

> **Control agent screen** — *Grants permission to connect to the screen,
> record it, view recordings and screenshots, and download them.*

### 3.2. Enable "Agent screen control" for the agent

`Contact center → Agents → <agent> → General`, then enable the
**Agent screen control** toggle.

This switch lets a supervisor follow the agent's screen. Note it cannot be
disabled per-agent while the same setting is enabled at the **Team** level — to
control it centrally, toggle it on the team instead.

### 3.3. Add the `wbt_record_screen` variable (automatic recording only)

This step is required **only for automatic screen recording** — recording that
starts on its own when a call comes in. For **manual** recording (started on
demand by a supervisor) it is **not needed**; sections 3.1–3.2 are enough.

Automatic recording starts only when the call carries a `wbt_record_screen`
variable. Add it either on the **Queue** or on the routing **Schema** that
handles the call:

- **Queue** — open the queue and add `wbt_record_screen` to its variables.
- **Schema** — set the `wbt_record_screen` variable inside the flow.

Set the value to `true` to trigger recording for calls going through that
queue / schema.

---

## 4. Launch & sign in

Start the app. On launch it opens a **webview login** — the same authorization
flow as the Webitel admin panel, served from your `server.baseUrl`. The agent
signs in there with their Webitel credentials.

Once authenticated, the app opens its WebSocket and is ready to record and
stream:

- **Automatic recording** starts on a call whose `wbt_record_screen` is set
  (section 3.3).
- **Manual** live view, recording, or screenshots can be requested on demand by
  a supervisor with the **Control agent screen** permission — no
  `wbt_record_screen` required.

For verbose WebSocket / WebRTC logging, set `telemetry.level` to `debug` in
`config.json`.
