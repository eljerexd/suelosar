import 'package:flutter/foundation.dart';

const bool updatePreviewModeEnabled =
    kDebugMode &&
    bool.fromEnvironment('SUelosAR_UPDATE_PREVIEW', defaultValue: false);

bool isUpdatePreviewAllowed({
  required bool debugBuild,
  required bool requested,
}) => debugBuild && requested;
