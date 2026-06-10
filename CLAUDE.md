# Webitel DeskTrack

Flutter desktop app for Webitel call-center agents. Streams the agent's screen and audio to supervisors via WebRTC, captures periodic screenshots, and records screen sessions on demand.

## Platforms

Primary target: **Windows**. macOS and Linux builds exist but are secondary.

## Architecture

```
WebSocket (ws/)
  └── NotificationHandler
        ├── ScreenStreamer      — real-time screen share to supervisor (WebRTC offer/answer)
        ├── RecordingManager   ← StreamRecorder
        │     └── Capturer     — getDisplayMedia (video + loopback audio) + getUserMedia (mic)
        └── ScreenshotService  — periodic + on-demand screenshots via desktop_screenshot
```

Key service paths:

| Layer | Path |
|-------|------|
| WebSocket core | `lib/ws/` |
| Notification routing | `lib/ws/handlers/notification_handler.dart` |
| Screen streaming | `lib/service/webrtc/streamer/streamer.dart` |
| WebRTC recording | `lib/service/webrtc/recorder/recorder.dart` |
| Audio + screen capture | `lib/service/webrtc/common/webrtc/capturer.dart` |
| FFmpeg binary lifecycle | `lib/service/ffmpeg/manager/manager.dart` |
| Screenshots | `lib/service/screenshot/` |
| App config | `lib/config/` |

## Audio + Video Capture (Windows)

Audio and video are captured via WebRTC APIs:

- **Screen video** — `getDisplayMedia({ video: { mandatory: { frameRate: 15 } } })` — 15 fps hardcoded
- **Loopback audio** — `getDisplayMedia({ audio: true })` — system audio via `ApplicationLoopbackCapturer` (Windows 10 20H2+, `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`)
- **Microphone** — `getUserMedia({ audio: true })` — agent mic as separate WebRTC track

Both audio tracks (loopback + mic) and the video track are sent as proper RTP streams to the recording server via `StreamRecorder`.

**Important:** Windows audio device must be set to **48000 Hz** (Sound Settings → Playback device → Advanced). If set to 44100 Hz, `ApplicationLoopbackCapturer` captures at 44100 Hz but the WebRTC pipeline timestamps audio as 48000 Hz, causing ~8.8% audio drift (audio runs ahead of video).

## Config

Loaded from `config.json` in the OS app-support directory at startup:

- Windows: `%APPDATA%\Webitel-Agent\config.json`
- macOS: `~/Library/Application Support/Webitel-Agent/config.json`

Key fields:

```json
{
  "server": { "baseUrl": "https://your-server.com" },
  "webrtc": {
    "iceServers": [{ "urls": "stun:stun.l.google.com:19302" }],
    "iceTransportPolicy": "all"
  }
}
```

## Code Conventions

- Comments **only in English**, only when the *why* is non-obvious — no narration of what the code does.
- No multi-line comment blocks or docstrings.
- Follow official Flutter/Dart style (`dart format`, `flutter analyze`).
- No feature flags, backwards-compatibility shims, or speculative abstractions.

## Build

```bash
# Windows (from Windows machine)
flutter build windows --release

# macOS
./build_macos.sh
```

FFmpeg binaries are bundled as Flutter assets:
- Windows: `assets/ffmpeg/windows/ffmpeg.exe`
- macOS: `assets/bin/macos/ffmpeg`

## Run / Debug

```bash
flutter run -d windows
flutter run -d macos
```

Set `DEBUG=true` in `.env` or config to enable verbose socket/FFmpeg logging.
