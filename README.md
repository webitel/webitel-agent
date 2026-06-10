# Webitel DeskTrack

A cross-platform desktop application for Webitel call-center agents. Streams the agent's screen to supervisors in real time, captures periodic screenshots, and records screen sessions driven by call-center events.

**Primary platform:** Windows. macOS and Linux builds are supported but secondary.

---

## Features

| Feature | Description |
| --- | --- |
| **Screen Recording** | Records screen + audio automatically when a call starts; stops after post-processing completes |
| **Live Screen Streaming** | Real-time WebRTC screen share to a supervisor on demand |
| **Periodic Screenshots** | Automatic screen captures uploaded to the server on a fixed interval |
| **Audio Capture** | System loopback + microphone captured as separate RTP tracks (Windows) |
| **OpenTelemetry** | Structured log export to an OTel collector |
| **Tray Menu** | Upload a new config file without restarting the application |

---

## Architecture

```text
AppFlow (singleton)
  ├── SocketManager ─── WebitelSocket
  │     ├── CallHandler          — call state machine; drives automatic recording
  │     └── NotificationHandler  — manual commands: share, screenshot, record
  ├── RecordingManager           — starts/stops StreamRecorder on call or manual signal
  │     └── StreamRecorder       — WebRTC peer connection to the recording server
  │           └── Capturer       — getDisplayMedia (video + loopback) + getUserMedia (mic)
  ├── ScreenStreamer              — separate WebRTC session for live supervisor view
  └── ScreenshotService          — periodic + on-demand screenshots
```

**Recording lifecycle:**

- **Start** — `CallHandler` detects a call with `record_screen=true` → `RecordingManager._onStart`
- **Stop** — socket stop signal, ICE Failed/Disconnected (10 s recovery window), or 1-hour safety timeout inside `StreamRecorder`

Key source paths:

| Layer | Path |
| --- | --- |
| App entry & lifecycle | `lib/app/flow.dart` |
| Call state machine | `lib/ws/handlers/call_handler.dart` |
| Notification routing | `lib/ws/handlers/notification_handler.dart` |
| Recording orchestration | `lib/app/recording_manager.dart` |
| WebRTC recording | `lib/service/webrtc/recorder/recorder.dart` |
| Live screen streaming | `lib/service/webrtc/streamer/streamer.dart` |
| Audio + screen capture | `lib/service/webrtc/common/webrtc/capturer.dart` |
| Screenshots | `lib/service/screenshot/` |
| App config | `lib/config/` |

---

## Audio & Video Capture (Windows)

All capture uses WebRTC APIs — no FFmpeg involved in recording:

- **Screen video** — `getDisplayMedia` at **15 fps** hardcoded via `frameRate: 15.0`
- **Loopback audio** — `getDisplayMedia({ audio: true })` via `ApplicationLoopbackCapturer` (Windows 10 20H2+)
- **Microphone** — `getUserMedia({ audio: true })` as a separate RTP track

All three tracks are sent as RTP streams to the recording server (`StreamRecorder`).

> **Important:** The Windows audio output device must be set to **48 000 Hz**.
> Sound Settings → Playback device → Properties → Advanced → Default Format → `48000 Hz`.
> At 44 100 Hz, `ApplicationLoopbackCapturer` introduces ~8.8 % audio clock drift.

---

## Configuration

Place a `config.json` file in the OS application-support directory before first launch:

| Platform | Path |
| --- | --- |
| Windows | `%APPDATA%\Webitel-Agent\config.json` |
| macOS | `~/Library/Application Support/Webitel-Agent/config.json` |
| Linux | `~/.config/Webitel-Agent/config.json` |

Use **Upload configuration** in the system tray to reload the file without restarting.

### Example `config.json`

```json
{
  "server": {
    "baseUrl": "https://your-host.webitel.com"
  },
  "telemetry": {
    "level": "info",
    "console": true,
    "file": {
      "enabled": true,
      "path": "logs/app.log"
    },
    "opentelemetry": {
      "enabled": false,
      "endpoint": "http://192.168.1.10:4317",
      "serviceName": "webitel-desk-track",
      "exportLogs": false
    }
  },
  "webrtc": {
    "iceServers": [],
    "iceTransportPolicy": "all"
  }
}
```

### Configuration Reference

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `server.baseUrl` | string | — | Base URL of the Webitel server |
| `telemetry.level` | string | `info` | Minimum log level: `debug`, `info`, `warn`, `error` |
| `telemetry.console` | bool | `true` | Print logs to stdout |
| `telemetry.file.enabled` | bool | `false` | Write logs to a file |
| `telemetry.file.path` | string | — | Log file path (relative or absolute) |
| `telemetry.opentelemetry.enabled` | bool | `false` | Enable OTel export |
| `telemetry.opentelemetry.endpoint` | string | — | OTel collector address (HTTP/gRPC) |
| `telemetry.opentelemetry.serviceName` | string | — | Service name tag in the OTel export |
| `telemetry.opentelemetry.exportLogs` | bool | `false` | Include logs in the OTel export |
| `webrtc.iceServers` | array | `[]` | STUN/TURN server list |
| `webrtc.iceTransportPolicy` | string | `all` | `all` or `relay` |

---

## Build

**Windows** (must be run on a Windows machine):

```bash
flutter build windows --release
```

**macOS** (includes code signing and notarization):

```bash
./build_macos.sh
```

FFmpeg binaries are bundled as Flutter assets (used for screenshots only):

| Platform | Asset path |
| --- | --- |
| Windows | `assets/ffmpeg/windows/ffmpeg.exe` |
| macOS | `assets/bin/macos/ffmpeg` |

---

## Development

```bash
# Windows
flutter run -d windows

# macOS
flutter run -d macos
```

Set `telemetry.level` to `debug` in `config.json` for verbose WebSocket and WebRTC logging.
