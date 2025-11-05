import 'package:flutter/material.dart';
import 'package:webitel_agent_flutter/app/initializer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppInitializer.run();
}
