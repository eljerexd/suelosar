import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../widgets/app_notification.dart';

final Future<Set<String>> _bundledAssetPaths =
    AssetManifest.loadFromAssetBundle(
      rootBundle,
    ).then((manifest) => manifest.listAssets().toSet());

class PdfViewerScreen extends StatelessWidget {
  const PdfViewerScreen({
    required this.title,
    required this.assetPath,
    super.key,
  });

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SfPdfViewer.asset(assetPath),
    );
  }
}

Future<bool> openLocalPdfViewer(
  BuildContext context, {
  required String title,
  required String assetPath,
  required String unavailableMessage,
}) async {
  final availableAssets = await _bundledAssetPaths;
  if (!availableAssets.contains(assetPath)) {
    if (context.mounted) {
      AppNotification.show(
        context,
        message: unavailableMessage,
        type: AppNotificationType.error,
      );
    }
    return false;
  }

  if (!context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PdfViewerScreen(title: title, assetPath: assetPath),
    ),
  );
  return true;
}
