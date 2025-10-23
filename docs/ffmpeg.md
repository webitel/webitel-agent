# 🚀 FFmpeg Installation Guide for Windows

This guide explains how to quickly and correctly install the **FFmpeg** multimedia framework on
Windows by adding it to the System PATH.

-----

## 📥 Step 1: Download FFmpeg

1. Go to the official FFmpeg download
   page: [https://ffmpeg.org/download.html\#build-windows](https://ffmpeg.org/download.html#build-windows).
2. Hover over the **Windows** icon and click on **“Windows builds from gyan.dev”**.
3. On the gyan.dev page, locate the **"git master builds"** section and click the link for *
   *`ffmpeg-git-full.7z`** to download the latest complete version.

-----

## 📂 Step 2: Extract the Archive

1. Use an archive program like **7-Zip** or **WinRAR** to extract the downloaded `.7z` file.

2. Extract the contents to a simple, easily accessible folder on your system, for example:

   ```
   C:\ffmpeg
   ```

   *(Ensure the main `ffmpeg` folder contains the `bin`, `doc`, and `presets` subfolders.)*

-----

## ⚙️ Step 3: Add FFmpeg to the System PATH

Adding the `bin` folder to your System PATH allows you to run `ffmpeg` commands from any directory
in Command Prompt or PowerShell.

1. Open **Control Panel** $\rightarrow$ **System and Security** $\rightarrow$ **System
   ** $\rightarrow$ **Advanced system settings**.

2. In the System Properties window, click the **Environment Variables** button.

3. Under the **System variables** section (the bottom list), find the variable named **`Path`** and
   click **Edit**.

4. In the "Edit environment variable" window, click **New** and enter the full path to the FFmpeg *
   *`bin`** folder. Following the example above, this path is:

   ```
   C:\ffmpeg\bin
   ```

5. Click **OK** on all open windows (Edit, Environment Variables, System Properties) to save the
   changes.

-----

## ✅ Step 4: Verify Installation

1. Open a new instance of **Command Prompt** (CMD) or **PowerShell**.

2. Run the following command:

   ```bash
   ffmpeg -version
   ```

3. If the installation was successful, you will see the detailed **FFmpeg version information**
   displayed.

🎉 You're all set\! FFmpeg is now correctly installed and accessible on your Windows system.