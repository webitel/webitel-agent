import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/core/logger.dart';

class FileStorageService {
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  bool isValidUuid(String id) => _uuid.hasMatch(id);

  Future<String> buildRecordingFilePath(String agentId) async {
    final dir = await getTemporaryDirectory();
    final recordingsDir = Directory('${dir.path}/recordings');
    if (!await recordingsDir.exists()) {
      await recordingsDir.create(recursive: true);
    }

    final now = DateTime.now();
    final fileName =
        'recording_ss_${agentId}_${now.toIso8601String().replaceAll(":", "-")}.mp4';
    return '${recordingsDir.path}/$fileName';
  }

  Future<void> cleanupOldVideos() async {
    final appDir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${appDir.path}/recordings');
    if (!await recDir.exists()) return;

    await for (final f in recDir.list()) {
      if (f is File) {
        await f.delete();
        logger.info('Deleted old video: ${f.path}');
      }
    }
  }
}
