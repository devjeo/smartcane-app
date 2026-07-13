import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';

/// Equivalent of the `<Modal visible={isModalVisible} ...>` block in logs.tsx.
/// Call via `showModalBottomSheet` from LogsScreen instead of RN's
/// always-mounted `<Modal>` + `visible` prop.
class FilterModalSheet extends StatefulWidget {
  final List<String> devices;
  final List<String> categories;
  final String activeDevice;
  final String activeCategory;

  const FilterModalSheet({
    super.key,
    required this.devices,
    required this.categories,
    required this.activeDevice,
    required this.activeCategory,
  });

  @override
  State<FilterModalSheet> createState() => _FilterModalSheetState();
}

class _FilterModalSheetState extends State<FilterModalSheet> {
  late String _activeDevice;
  late String _activeCategory;

  @override
  void initState() {
    super.initState();
    _activeDevice = widget.activeDevice;
    _activeCategory = widget.activeCategory;
  }

  void _clearFilters() {
    setState(() {
      _activeDevice = 'All Devices';
      _activeCategory = 'All Types';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 25, 20, bottomInset + 20),
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Filter Logs',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textMain)),
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.textSub),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Select Device',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                  const SizedBox(height: 15),
                  _ChipWrap(
                    options: widget.devices,
                    active: _activeDevice,
                    onSelected: (v) => setState(() => _activeDevice = v),
                  ),
                  const SizedBox(height: 10),
                  const Text('Event Type',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                  const SizedBox(height: 15),
                  _ChipWrap(
                    options: widget.categories,
                    active: _activeCategory,
                    onSelected: (v) => setState(() => _activeCategory = v),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: 20),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _clearFilters,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.chipBg,
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Reset',
                        style: TextStyle(color: AppColors.textSub, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop({
                      'activeDevice': _activeDevice,
                      'activeCategory': _activeCategory,
                    }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Show Results',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipWrap extends StatelessWidget {
  final List<String> options;
  final String active;
  final ValueChanged<String> onSelected;

  const _ChipWrap({required this.options, required this.active, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((option) {
        final isActive = option == active;
        return GestureDetector(
          onTap: () => onSelected(option),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isActive ? AppColors.primary : AppColors.chipBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isActive ? AppColors.primary : AppColors.border),
            ),
            child: Text(
              option,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isActive ? Colors.white : AppColors.textSub,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
