# Webitel DeskTrack

Flutter desktop app for Webitel call-center agents. Streams the agent's screen and audio to supervisors via WebRTC, captures periodic screenshots, and records screen sessions on demand.

## Platforms

Primary target: **Windows**. macOS and Linux builds exist but are secondary.

## Architecture

```
WebSocket (ws/)
  └── NotificationHandler
        ├── ScreenStreamer      — real-time screen share to supervisor (WebRTC offer/answer)
        ├── RecordingManager   ← StreamRecorder / LocalVideoRecorder
        │     └── Capturer     — enumerates DirectShow devices, runs FFmpeg for audio
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
| Local file recording | `lib/service/ffmpeg/recorder/` |
| Screenshots | `lib/service/screenshot/` |
| App config | `lib/config/` |

## Audio Capture (Windows)

Audio is captured by FFmpeg using DirectShow (`-f dshow`). The app enumerates devices with `ffmpeg -list_devices true -f dshow -i dummy` and searches by keyword for:

- **Stereo Mix** — system audio loopback (`AppConfig.stereoMixKeywords`, default: `['Stereo Mix']`)
- **Microphone** — agent mic (`AppConfig.microphoneKeywords`, default: `['Microphone']`)

Before starting capture, each found device is probed with a 0.1 s test recording to confirm it can actually be opened. If Stereo Mix is disabled in Windows Sound settings it will appear in the device list but fail the probe — the app then falls back to **microphone-only** audio. Recording proceeds without system audio rather than failing entirely.

## Config

Loaded from `config.json` in the OS app-support directory at startup:

- Windows: `%APPDATA%\Webitel-Agent\config.json`
- macOS: `~/Library/Application Support/Webitel-Agent/config.json`

Key fields: `server`, `devices.stereoMixKeywords`, `devices.microphoneKeywords`, `video.width`, `video.height`, `videoSaveLocally`.

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
