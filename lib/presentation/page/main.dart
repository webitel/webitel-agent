import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../gen/assets.gen.dart';
import '../theme/text_style.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  // No AppLifecycleListener here: closing the window only hides it to the tray
  // (AppFlow.onWindowClose) and the only exit is the tray's "Close"
  // (AppFlow.quit). A shutdown() from lifecycle callbacks would stop recording
  // and disconnect while the agent keeps running hidden.

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
        child: Stack(
          children: [
            Center(
              child: Container(
                width: 380,
                height: 260,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SvgPicture.asset(
                      Assets.icons.webitelDeskTrackSuccessfully,
                      width: 72,
                      height: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'You have been successfully logged in',
                      style: AppTextStyles.captureTitle.copyWith(
                        color: Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You can now continue your work in Workspace',
                      style: AppTextStyles.captureSubtitle.copyWith(
                        color: Colors.black54,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
