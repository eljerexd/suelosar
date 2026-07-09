import 'package:flutter/material.dart';

import '../constants/app_icons.dart';
import '../models/personal_marker.dart';

IconData personalMarkerCategoryIcon(PersonalMarkerCategory category) {
  return switch (category) {
    PersonalMarkerCategory.sampling => AppIcons.sampling,
    PersonalMarkerCategory.soilPit => AppIcons.soilPit,
    PersonalMarkerCategory.floodProneLowland => AppIcons.floodArea,
    PersonalMarkerCategory.observation => AppIcons.observation,
    PersonalMarkerCategory.infrastructure => AppIcons.infrastructure,
    PersonalMarkerCategory.other => AppIcons.location,
  };
}
