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

Recording and screen monitoring are gated by three back-office settings. All
three are configured in the Webitel admin UI.

### 3.1. Add the `wbt_record_screen` variable

Screen recording starts only when the call carries a `wbt_record_screen`
variable. Add it either on the **Queue** or on the routing **Schema** that
handles the call:

- **Queue** — open the queue and add `wbt_record_screen` to its variables.
- **Schema** — set the `wbt_record_screen` variable inside the flow.

Set the value to `true` to trigger recording for calls going through that
queue / schema.

### 3.2. Grant the "Control agent screen" permission

The role of anyone who needs to connect to, record, view, or download an
agent's screen must hold the **Control agent screen** permission.

`Permissions → Roles → <role> → Role permissions`, then add:

> **Control agent screen** — *Grants permission to connect to the screen,
> record it, view recordings and screenshots, and download them.*

### 3.3. Enable "Agent screen control" for the agent

`Contact center → Agents → <agent> → General`, then enable the
**Agent screen control** toggle.

This switch lets a supervisor follow the agent's screen. Note it cannot be
disabled per-agent while the same setting is enabled at the **Team** level — to
control it centrally, toggle it on the team instead.

---

## 4. Launch & sign in

Start the app. On launch it opens a **webview login** — the same authorization
flow as the Webitel admin panel, served from your `server.baseUrl`. The agent
signs in there with their Webitel credentials.

Once authenticated, the app opens its WebSocket and is ready to record and
stream:

- Recording starts automatically on a call whose `wbt_record_screen` is set.
- A supervisor with **Control agent screen** can request a live view or a
  screenshot on demand.

For verbose WebSocket / WebRTC logging, set `telemetry.level` to `debug` in
`config.json`.
