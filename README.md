# 🖥 Webitel-Agent

Cross-platform desktop application (Windows/macOS/Linux) for Webitel call center integration.

-----

## 🚀 Key Features

| Feature                      | Description                                                       |
|:-----------------------------|:------------------------------------------------------------------|
| **🖼️ Periodic Screenshots** | Automatic screen captures (configurable via `config.json`)        |
| **🎥 Screen Recording**      | Starts recording based on Webitel socket events                   |
| **📡 Live Screen Streaming** | Real-time agent screen sharing via WebRTC for supervisors         |
| **🧠 Configurable Behavior** | Controlled through the `config.json` file                         |
| **🪵 Logging**               | File-based logging of activities and errors (when enabled)        |
| **🖱 Tray Menu**             | Manual configuration upload via the "Upload configuration" option |

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

## 🧾 Example `config.json`

```json
{
  "server": {
    "baseUrl": "https://hostname"
  },
  "media": {
    "screenshotEnabled": true
  },
  "logger": {
    "info": true,
    "debug": true,
    "error": true,
    "toFile": true,
    "filePath": "logs/app.log"
  },
  "webrtc": {
    "iceServers": []
  },
  "video": {
    "width": 1920,
    "height": 1080,
    "framerate": 30,
    "saveLocally": false
  }
}
```

-----

## 🧩 Configuration Reference (Updated)

| Key                           | Description                                           |
|:------------------------------|:------------------------------------------------------|
| **`server.baseUrl`**          | Base URL of the Webitel server                        |
| **`media.screenshotEnabled`** | Enable/disable periodic screenshots (`true`/`false`)  |
| **`logger.info`**             | Enable info-level logging                             |
| **`logger.debug`**            | Enable debug-level logging                            |
| **`logger.error`**            | Enable error-level logging                            |
| **`logger.toFile`**           | Enable writing logs to a file                         |
| **`logger.filePath`**         | Path to log file (relative to project or absolute)    |
| **`webrtc.iceServers`**       | List of STUN/TURN servers for WebRTC sessions         |
| **`video.width`**             | Width of the captured video/screenshot in pixels      |
| **`video.height`**            | Height of the captured video/screenshot in pixels     |
| **`video.framerate`**         | Capture frame rate in frames per second (FPS)         |
| **`video.saveLocally`**       | Save captured video locally using FFmpeg for encoding |

-----