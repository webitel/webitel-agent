# Webitel DeskTrack

A cross-platform desktop application for Webitel call-center agents. It monitors agent activity by streaming the screen to supervisors in real time, capturing periodic screenshots, and recording screen sessions triggered by call-center events.

**Primary platform:** Windows. macOS and Linux builds are supported but secondary.

---

## Features

| Feature | Description |
| --- | --- |
| **Periodic Screenshots** | Automatic screen captures sent to the Webitel server on a configurable interval |
| **Screen Recording** | Records the agent's screen in response to WebSocket events from the Webitel server |
| **Live Screen Streaming** | Real-time screen share to supervisors via WebRTC (offer/answer signaling over WebSocket) |
| **Audio Capture** | Captures system audio (Stereo Mix) and microphone via FFmpeg DirectShow on Windows |
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
        │     ├── WebRTC Recorder  — records via flutter_webrtc
        │     └── FFmpeg Recorder  — records via bundled FFmpeg binary
        │           └── Capturer   — enumerates DirectShow devices, probes and opens audio
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
| Local file recording | `lib/service/ffmpeg/recorder/` |
| Screenshots | `lib/service/screenshot/` |
| App config | `lib/config/` |

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
    "level": "debug",
    "console": true,
    "file": {
      "enabled": true,
      "path": "logs/app.log"
    },
    "opentelemetry": {
      "enabled": true,
      "endpoint": "http://192.168.1.10:4317",
      "serviceName": "webitel-desk-track",
      "exportLogs": true
    }
  },
  "webrtc": {
    "iceServers": [],
    "iceTransportPolicy": "all",
    "enableMetrics": true
  },
  "video": {
    "width": 1920,
    "height": 1080,
    "saveLocally": false,
    "maxCallRecordDuration": 600
  },
  "devices": {
    "stereoMixKeywords": ["Stereo Mix"],
    "microphoneKeywords": ["Microphone"]
  }
}
```

### Configuration Reference

| Key | Type | Description |
| --- | --- | --- |
| `server.baseUrl` | string | Base URL of the Webitel server |
| `telemetry.level` | string | Minimum log level: `debug`, `info`, `error` |
| `telemetry.console` | bool | Print logs to stdout |
| `telemetry.file.enabled` | bool | Write logs to a file |
| `telemetry.file.path` | string | Log file path (relative or absolute) |
| `telemetry.opentelemetry.enabled` | bool | Enable OTel export |
| `telemetry.opentelemetry.endpoint` | string | OTel collector address (HTTP/gRPC) |
| `telemetry.opentelemetry.serviceName` | string | Service name reported to the collector |
| `telemetry.opentelemetry.exportLogs` | bool | Include logs in OTel export |
| `webrtc.iceServers` | array | STUN/TURN server list for WebRTC |
| `webrtc.iceTransportPolicy` | string | `all` or `relay` |
| `webrtc.enableMetrics` | bool | Log WebRTC performance metrics periodically (requires `level: debug`) |
| `video.width` | int | Capture width in pixels |
| `video.height` | int | Capture height in pixels |
| `video.saveLocally` | bool | Save recorded video to disk |
| `video.maxCallRecordDuration` | int | Maximum recording duration in seconds |
| `devices.stereoMixKeywords` | array | Keywords used to identify the Stereo Mix device |
| `devices.microphoneKeywords` | array | Keywords used to identify the microphone device |

---

## Audio Capture (Windows)

Audio is captured by FFmpeg using DirectShow (`-f dshow`). The app enumerates devices via `ffmpeg -list_devices true -f dshow -i dummy` and matches them by keyword against `stereoMixKeywords` and `microphoneKeywords`.

Before starting a recording session, each matched device is probed with a short 0.1 s test recording. If Stereo Mix is disabled in Windows Sound settings it will appear in the device list but fail the probe — the app falls back to microphone-only audio and proceeds rather than failing.

---

## WebRTC Metrics

When `webrtc.enableMetrics: true` and `telemetry.level: debug`, the app logs a periodic performance snapshot for the active stream:

```text
[Metrics] FPS=12.0 res=1920x1080 frames(S/E)=12/12 encT(avg)=29ms/frame
          key=1 targetBitrate=2083k ACTUAL_BITRATE=1579kbps
          nack=0 pli=0 fir=0 RTT=4.2ms ICE=succeeded writable=true
```

| Field | Description |
| --- | --- |
| `FPS` | Frames sent per second over the network |
| `res` | Captured screen resolution |
| `frames(S/E)` | Sent vs. encoded frames — equal values indicate a healthy stream |
| `encT(avg)` | Average CPU encode time per frame |
| `ACTUAL_BITRATE` | Measured outgoing bitrate in the last reporting interval |
| `targetBitrate` | Encoder's requested bitrate |
| `nack/pli/fir` | Packet-loss recovery counters — zero is healthy |
| `RTT` | Round-trip network latency |
| `ICE` | ICE connection state — `succeeded` confirms an established path |

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

FFmpeg binaries are bundled as Flutter assets:

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

Set `telemetry.level` to `debug` in `config.json` to enable verbose WebSocket and FFmpeg logging.
