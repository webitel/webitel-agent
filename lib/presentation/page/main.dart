import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:webitel_agent_flutter/gen/assets.gen.dart';
import 'package:webitel_agent_flutter/presentation/theme/defaults.dart';
import 'package:webitel_agent_flutter/presentation/theme/text_style.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key});

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
          children: [
            const Spacer(),
            Center(
              child: SvgPicture.asset(
                Assets.icons.webitelMain,
                width: 70,
                height: 70,
              ),
            ),
            const Spacer(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  Defaults.captureTitle,
                  style: AppTextStyles.captureTitle,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 4),
                Text(
                  Defaults.captureSubtitle,
                  style: AppTextStyles.captureSubtitle,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
