import 'package:flutter/material.dart';

class PracticeNavigation extends StatelessWidget {
  const PracticeNavigation({
    super.key,
    required this.current,
    this.onPractice,
    this.onHistory,
    this.onAccount,
  });
  final String current;
  final VoidCallback? onPractice, onHistory, onAccount;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final entry in [
        (id: 'practice', label: '练习', action: onPractice),
        (id: 'history', label: '记录', action: onHistory),
        (id: 'account', label: '我的', action: onAccount),
      ])
        Semantics(
          selected: current == entry.id,
          child: OutlinedButton(
            onPressed: current == entry.id ? null : entry.action,
            child: Text(entry.label),
          ),
        ),
    ],
  );
}
