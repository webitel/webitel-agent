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
    "baseUrl": "[https://test-host.webitel.com](https://test-host.webitel.com)"
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
      "endpoint": "[http://192.168.1.10:4317](http://192.168.1.10:4317)",
      "serviceName": "webitel-desk-track-test",
      "exportLogs": true
    }
  },
  "webrtc": {
    "iceServers": [],
    "iceTransportPolicy": "all",
    "enableMetrics": true // <-- NEW: Enable WebRTC performance logging
  },
  "video": {
    "width": 1920,
    "height": 1080,
    "saveLocally": false,
    "maxCallRecordDuration": 600
  }
}
````

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
| **`webrtc.enableMetrics`** | **NEW:** If `true`, enables periodic WebRTC performance logging (CPU, bitrate, RTT, packet loss). Requires `telemetry.level` set to **`debug`** or lower. |
| **`video.width`** | Width of the captured video/screenshot in pixels |
| **`video.height`** | Height of the captured video/screenshot in pixels |
| **`video.saveLocally`** | Save captured video locally |
| **`video.maxCallRecordDuration`** | Maximum call recording duration in seconds (e.g., **`600`** sec) |

-----

## ⚙️ WebRTC Metrics Logging

When `webrtc.enableMetrics` is set to `true` and the log level is `debug`, the application periodically logs the performance and health of the active WebRTC stream (Screen Streaming).

### 📖 Example Log Breakdown

```
[Metrics] FPS=12.0 res=3600x2338 frames(S/E)=3/3 encT(total)=88.0ms encT(avg)=29.3ms/frame key=1 ↑pkts=189 ↑bytes=202983 ↓bytes=1375 targetBitrate=2083k ACTUAL_BITRATE=1579kbps nack=0 pli=0 fir=0 RTT=0.0ms ICE=succeeded writable=true nominated=true
```

| Metric | What it Measures | Interpretation |
|:---|:---|:---|
| **`FPS=12.0`** | **Frames Per Second** | The actual frequency of frames being sent over the network. |
| **`res=3600x2338`** | **Resolution** | The pixel dimensions of the captured screen. (High values require more resources). |
| **`frames(S/E)=3/3`**| **Sent/Encoded** | Number of frames *sent* vs. *encoded* in the last second. Should be equal (`S=E`) for a healthy stream. |
| **`encT(avg)=29.3ms/frame`** | **Average Encode Time** | Average time the local CPU took to compress one frame. **Indicates CPU Load.** Lower is better. |
| **`ACTUAL_BITRATE=1579kbps`** | **Actual Outgoing Bitrate** | The actual data rate used by the stream in the last second. |
| **`targetBitrate=2083k`** | **Target Bitrate** | The desired data rate requested by the encoder. |
| **`nack/pli/fir=0/0/0`** | **Error Recovery** | Counters for requests to re-send lost packets (`nack`) or full frames (`pli`/`fir`). **Zero is ideal**, indicating no packet loss or severe decoding issues. |
| **`RTT=0.0ms`** | **Round Trip Time** | Network latency (ping time). A value of `0.0ms` often means the metric was not properly calculated in this specific report or it's a very low-latency local connection. |
| **`ICE=succeeded`** | **ICE State** | Confirms that the connection (path discovery) was successfully established. |