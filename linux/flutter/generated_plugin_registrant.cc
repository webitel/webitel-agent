//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <desktop_screenshot/desktop_screenshot_plugin.h>
#include <file_selector_linux/file_selector_plugin.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <screen_capturer_linux/screen_capturer_linux_plugin.h>
#include <tray_manager/tray_manager_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) desktop_screenshot_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "DesktopScreenshotPlugin");
  desktop_screenshot_plugin_register_with_registrar(desktop_screenshot_registrar);
  g_autoptr(FlPluginRegistrar) file_selector_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FileSelectorPlugin");
  file_selector_plugin_register_with_registrar(file_selector_linux_registrar);
  g_autoptr(FlPluginRegistrar) flutter_webrtc_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FlutterWebRTCPlugin");
  flutter_web_r_t_c_plugin_register_with_registrar(flutter_webrtc_registrar);
  g_autoptr(FlPluginRegistrar) screen_capturer_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ScreenCapturerLinuxPlugin");
  screen_capturer_linux_plugin_register_with_registrar(screen_capturer_linux_registrar);
  g_autoptr(FlPluginRegistrar) tray_manager_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "TrayManagerPlugin");
  tray_manager_plugin_register_with_registrar(tray_manager_registrar);
}
