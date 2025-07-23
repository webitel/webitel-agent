import 'package:flutter/material.dart';
import 'package:webitel_agent_flutter/presentation/theme/text_style.dart';

class MissingConfigPage extends StatelessWidget {
  const MissingConfigPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-0.47, -1.0),
            end: Alignment(1.0, 1.0),
            colors: [Color(0xFFD93DF5), Color(0xFF1A2EB2)],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Configuration file not found',
              style: AppTextStyles.captureTitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Please upload the configuration file via the tray to continue.',
              style: AppTextStyles.captureSubtitle,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
