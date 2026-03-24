import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/initializer.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ensure only one instance of the app is running on Windows
  await WindowsSingleInstance.ensureSingleInstance(
    args,
    "webitel_desk_track_instance_root",
    onSecondWindow: (secondWindowArgs) {
      // Logic to handle second instance launch (e.g., focus window)
      logger.info('Second instance detected with args: $secondWindowArgs');
    },
  );

  await AppInitializer.run();
}
