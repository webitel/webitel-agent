//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <desktop_screenshot/desktop_screenshot_plugin_c_api.h>
#include <file_selector_windows/file_selector_windows.h>
#include <flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <screen_capturer_windows/screen_capturer_windows_plugin_c_api.h>
#include <tray_manager/tray_manager_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ConnectivityPlusWindowsPlugin"));
  DesktopScreenshotPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopScreenshotPluginCApi"));
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterInappwebviewWindowsPluginCApi"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
  ScreenCapturerWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenCapturerWindowsPluginCApi"));
  TrayManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TrayManagerPlugin"));
}
