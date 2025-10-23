FFmpeg Installation on Windows 🖥️

This guide explains how to quickly and correctly install FFmpeg on Windows.

⸻

📥 Step 1: Download FFmpeg

1. Go to the FFmpeg official website - https://ffmpeg.org/download.html#build-windows
2. Hover over Windows and click on “Windows builds from gyan.dev”.
3. On the gyan.dev page, in the “git master builds” section, click “ffmpeg-git-full.7z” to download
   the latest version.

⸻

📂 Step 2: Extract the Archive

1. Use a program like 7-Zip or WinRAR.
2. Extract the archive to a folder of your choice, e.g.:

C:\ffmpeg

⸻

⚙️ Step 3: Add FFmpeg to the System PATH

1. Open Control Panel → System and Security → System → Advanced system settings.
2. Click Environment Variables.
3. Under System variables, find Path and click Edit.
4. Click New and enter the path to the bin folder inside FFmpeg, e.g.:

C:\ffmpeg\bin

	5.	Click OK to save all changes.

⸻

✅ Step 4: Verify Installation

1. Open Command Prompt or PowerShell.
2. Run:

ffmpeg -version

	3.	You should see the FFmpeg version information.