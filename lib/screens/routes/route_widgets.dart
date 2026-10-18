import 'package:flutter/material.dart';
import '../../models/route_model.dart';
import '../../theme/app_colors.dart';

/// Icon for a turn, shared by the editor, the route list and (later) the
/// walking screens.
IconData maneuverIcon(String maneuver) {
  switch (maneuver) {
    case Maneuver.depart:
      return Icons.directions_walk;
    case Maneuver.slightLeft:
      return Icons.turn_slight_left;
    case Maneuver.left:
      return Icons.turn_left;
    case Maneuver.sharpLeft:
      return Icons.turn_sharp_left;
    case Maneuver.slightRight:
      return Icons.turn_slight_right;
    case Maneuver.right:
      return Icons.turn_right;
    case Maneuver.sharpRight:
      return Icons.turn_sharp_right;
    case Maneuver.uTurnLeft:
      return Icons.u_turn_left;
    case Maneuver.uTurnRight:
      return Icons.u_turn_right;
    case Maneuver.arrive:
      return Icons.flag;
    default:
      return Icons.straight;
  }
}

/// Plain list of turn-by-turn steps.
class StepsList extends StatelessWidget {
  final List<RouteStep> steps;
  final ScrollController? controller;
  const StepsList({super.key, required this.steps, this.controller});

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('No steps yet.', style: TextStyle(color: AppColors.textSub)),
      );
    }
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: steps.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) {
        final s = steps[i];
        return ListTile(
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: s.isArrival ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              maneuverIcon(s.maneuver),
              size: 22,
              color: s.isArrival ? AppColors.success : AppColors.primary,
            ),
          ),
          title: Text(s.text,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textMain)),
          subtitle: s.isArrival
              ? null
              : Text('then ${formatDistance(s.distM)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
        );
      },
    );
  }
}

/// Small "Destination" / "Google" / "Hand drawn" pill.
class SourceBadge extends StatelessWidget {
  final bool drawn;
  final bool destination;
  const SourceBadge({super.key, required this.drawn, this.destination = false});

  @override
  Widget build(BuildContext context) {
    final bg = destination
        ? const Color(0xFFDCFCE7)
        : drawn
            ? const Color(0xFFFEF3C7)
            : const Color(0xFFE0F2FE);
    final fg = destination
        ? AppColors.success
        : drawn
            ? const Color(0xFFB45309)
            : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        destination ? 'Destination' : (drawn ? 'Hand drawn' : 'Google'),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }
}

/// Shows an error in a simple dialog.
Future<void> showRouteAlert(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
      ],
    ),
  );
}
