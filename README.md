# 🖥 Webitel-Agent

Cross-platform desktop application (Windows/macOS/Linux) for Webitel call center integration.

-----

## 🚀 Key Features

| Feature | Description |
|:---|:---|
| **🖼️ Periodic Screenshots** | Automatic screen captures |
| **🎥 Screen Recording** | Starts recording based on Webitel socket events |
| **📡 Live Screen Streaming** | Real-time agent screen sharing via WebRTC for supervisors |
| **🧠 Configurable Behavior** | Controlled through the `config.json` file |
| **🪵 Logging** | File-based logging of activities and errors (when enabled) |
| **🖱 Tray Menu** | Manual configuration upload via the "Upload configuration" option |

-----

## 📁 Configuration

Place a **`config.json`** file in the application support directory:

### 🔧 Platform Paths

  * **Windows**: `C:\Users\<username>\AppData\Roaming\Webitel-Agent`
  * **macOS**: `/Users/<username>/Library/Application Support/Webitel-Agent`
  * **Linux**: `/home/<username>/.config/Webitel-Agent`

💡 **Retrieve path programmatically**:
Use: `final appSupportDir = await getApplicationSupportDirectory();`

⚠️ **Missing Config File?**
Use the **"Upload configuration"** option in the tray menu to manually load your configuration.

-----

## 🧾 Example `config.json` (Updated)

```json
{
  "server": {
    "baseUrl": "https://test-host.webitel.com"
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
      "serviceName": "webitel-desk-track-test",
      "exportLogs": true
    }
  },
  "webrtc": {
    "iceServers": [],
    "iceTransportPolicy": "all"
  },
  "video": {
    "width": 1920,
    "height": 1080,
    "saveLocally": false,
    "maxCallRecordDuration": 600
  }
}
```

-----

## 🧩 Configuration Reference (Updated)

| Key | Description |
|:---|:---|
| **`server.baseUrl`** | Base URL of the Webitel server (e.g., `https://test-host.webitel.com`) |
| **`telemetry.level`** | Minimum logging level (**`info`**, **`debug`**, **`error`**) |
| **`telemetry.console`** | Enable logging output to the console |
| **`telemetry.file.enabled`** | Enable writing logs to a file |
| **`telemetry.file.path`** | Path to the log file (relative or absolute) |
| **`telemetry.opentelemetry.enabled`** | Enable exporting metrics/traces/logs via OpenTelemetry |
| **`telemetry.opentelemetry.endpoint`**| HTTP/gRPC address of the OpenTelemetry collector (e.g., `http://192.168.1.10:4317`) |
| **`telemetry.opentelemetry.serviceName`** | Service name for OpenTelemetry (e.g., `webitel-desk-track-test`) |
| **`telemetry.opentelemetry.exportLogs`** | Export logs via OpenTelemetry |
| **`webrtc.iceServers`** | List of STUN/TURN servers for WebRTC sessions |
| **`webrtc.iceTransportPolicy`**| ICE transport policy (**`all`** or **`relay`**) |
| **`video.width`** | Width of the captured video/screenshot in pixels |
| **`video.height`** | Height of the captured video/screenshot in pixels |
| **`video.saveLocally`** | Save captured video locally |
| **`video.maxCallRecordDuration`** | Maximum call recording duration in seconds (e.g., **`600`** sec) |
