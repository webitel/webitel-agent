import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/initializer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppInitializer.run();
}
