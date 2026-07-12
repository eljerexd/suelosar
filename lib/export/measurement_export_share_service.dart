import 'dart:io';

import 'package:share_plus/share_plus.dart';

class MeasurementExportShareService {
  const MeasurementExportShareService();

  Future<void> share({
    required File file,
    required String mimeType,
    required String text,
  }) {
    return SharePlus.instance.share(
      ShareParams(
        text: text,
        files: [XFile(file.path, mimeType: mimeType)],
      ),
    );
  }
}
