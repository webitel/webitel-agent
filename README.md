# Webitel DeskTrack

A cross-platform desktop application for Webitel call-center agents. It monitors agent activity by streaming the screen to supervisors in real time, capturing periodic screenshots, and recording screen sessions triggered by call-center events.

**Primary platform:** Windows. macOS and Linux builds are supported but secondary.

---

## Features

| Feature | Description |
| --- | --- |
| **Periodic Screenshots** | Automatic screen captures sent to the Webitel server on a configurable interval |
| **Screen Recording** | Records the agent's screen + audio in response to WebSocket events from the Webitel server |
| **Live Screen Streaming** | Real-time screen share to supervisors via WebRTC (offer/answer signaling over WebSocket) |
| **Audio Capture** | System audio (loopback) and microphone captured as WebRTC tracks via Windows Application Loopback API |
| **OpenTelemetry** | Structured log export to an OTel collector (logs, traces) |
| **WebRTC Metrics** | Periodic performance logging: FPS, bitrate, RTT, packet loss, ICE state |
| **Tray Menu** | Manual configuration upload without restarting the application |

---

## Architecture

```text
WebSocket (lib/ws/)
  └── NotificationHandler
        ├── ScreenStreamer      — real-time WebRTC screen share to supervisor
        ├── RecordingManager
        │     └── StreamRecorder  — records screen + audio via WebRTC to server
        │           └── Capturer  — getDisplayMedia (video + loopback) + getUserMedia (mic)
        └── ScreenshotService  — periodic and on-demand screenshots
```

Key source paths:

| Layer | Path |
| --- | --- |
| WebSocket core | `lib/ws/` |
| Notification routing | `lib/ws/handlers/notification_handler.dart` |
| Screen streaming (WebRTC) | `lib/service/webrtc/streamer/streamer.dart` |
| WebRTC recording | `lib/service/webrtc/recorder/recorder.dart` |
| Audio + screen capture | `lib/service/webrtc/common/webrtc/capturer.dart` |
| FFmpeg binary lifecycle | `lib/service/ffmpeg/manager/manager.dart` |
| Screenshots | `lib/service/screenshot/` |
| App config | `lib/config/` |

---

## Audio & Video Capture (Windows)

All capture is done via WebRTC APIs — no FFmpeg for recording:

- **Screen video** — `getDisplayMedia` at **15 fps** (hardcoded)
- **Loopback audio** — `getDisplayMedia({ audio: true })` via `ApplicationLoopbackCapturer` (Windows 10 20H2+)
- **Microphone** — `getUserMedia({ audio: true })` as a separate RTP track

Both audio tracks and the video track are sent as RTP streams to the recording server via `StreamRecorder`.

> **Important:** The Windows audio output device must be set to **48000 Hz**.
> Go to Sound Settings → Playback device → Properties → Advanced → Default Format → select `48000 Hz`.
> At 44100 Hz, `ApplicationLoopbackCapturer` introduces ~8.8% clock drift (audio runs ahead of video).

---

## Configuration

On first launch, place a `config.json` file in the OS application-support directory:

| Platform | Path |
| --- | --- |
| Windows | `%APPDATA%\Webitel-Agent\config.json` |
| macOS | `~/Library/Application Support/Webitel-Agent/config.json` |
| Linux | `~/.config/Webitel-Agent/config.json` |

Alternatively, use the **Upload configuration** option in the system tray menu to load the file manually.

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
      "exportLogs": true
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
| `telemetry.opentelemetry.serviceName` | string | — | Service name reported to the collector |
| `telemetry.opentelemetry.exportLogs` | bool | `true` | Include logs in OTel export |
| `webrtc.iceServers` | array | `[]` | STUN/TURN server list for WebRTC |
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
# Run on Windows
flutter run -d windows

# Run on macOS
flutter run -d macos
```

Set `telemetry.level` to `debug` in `config.json` to enable verbose WebSocket and WebRTC logging.
