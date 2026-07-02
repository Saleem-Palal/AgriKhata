import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';
// import 'package:your_app_name/core/constants/app_colors.dart';

class SeasonSelector extends StatefulWidget {
  final Function(List<String>) onSeasonsChanged;
  final Function(List<String>) onCropsChanged;

  const SeasonSelector({
    super.key,
    required this.onSeasonsChanged,
    required this.onCropsChanged,
  });

  @override
  State<SeasonSelector> createState() => _SeasonSelectorState();
}

class _SeasonSelectorState extends State<SeasonSelector> {
  // 1. All your state variables move here
  List<String> selectedSeasons = [];
  List<String> selectedCrops = [];

  final Map<String, List<String>> seasonCrops = {
    'Rabi': ['Wheat', 'Mustard', 'Potato', 'Onion', 'Chili'],
    'Kharif': [
      'Rice',
      'Cotton',
      'Sugarcane',
      'Maize',
      'Sunflower',
      'Tomato',
      'Mango',
    ],
  };

  @override
  Widget build(BuildContext context) {
    // 2. The logic for filtering stays inside build
    List<String> availableCrops = [];
    for (var season in selectedSeasons) {
      availableCrops.addAll(seasonCrops[season] ?? []);
    }
    availableCrops = availableCrops.toSet().toList();

    //final VoidCallback onSelectionChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Active seasons",
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildSeasonCard(
                "Rabi",
                "Oct – Apr · Wheat, Mustard",
                selectedSeasons.contains("Rabi"),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSeasonCard(
                "Kharif",
                "May – Sep · Rice, Cotton",
                selectedSeasons.contains("Kharif"),
              ),
            ),
          ],
        ),
        if (selectedSeasons.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Primary crops",
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              Text(
                "tap to select",
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: availableCrops
                .map((crop) => _buildCropPill(crop))
                .toList(),
          ),
        ],
      ],
    );
  }

  // 3. Move your helper builders inside the State class
  Widget _buildSeasonCard(String title, String subtitle, bool isSelected) {
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            //widget.onSelectionChanged();
            selectedSeasons.remove(title);
            // Clean up crops that no longer have an active season
            selectedCrops.removeWhere(
              (c) => !selectedSeasons.any((s) => seasonCrops[s]!.contains(c)),
            );
          } else {
            selectedSeasons.add(title);
          }
          // NOTIFY PARENT
          widget.onSeasonsChanged(selectedSeasons);
          widget.onCropsChanged(selectedCrops);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.activeSeasonBadge : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? AppColors.darkGreen.withValues(alpha: 0.5)
                : AppColors.sidebarBg,
            width: isSelected ? 1 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                height: 1,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isSelected ? AppColors.darkGreen : Colors.black87,
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropPill(String crop) {
    bool isSelected = selectedCrops.contains(crop);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            selectedCrops.remove(crop);
          } else {
            selectedCrops.add(crop);
          }

          // 2. IMMEDIATE SYNC: Send a NEW list instance to the parent
          // Adding .toList() creates a fresh copy so the parent detects the change
          widget.onCropsChanged(List.from(selectedCrops));
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF1F8E9) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppColors.darkGreen.withValues(alpha: 0.5)
                : AppColors.sidebarBg,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected)
              const Icon(Icons.check, size: 14, color: AppColors.darkGreen),
            if (isSelected) const SizedBox(width: 4),
            Text(
              crop,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? AppColors.darkGreen : AppColors.textMuted,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
