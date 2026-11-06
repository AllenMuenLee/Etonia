import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../../../app/theme/app_tokens.dart';
import '../../../../app/theme/app_theme.dart';

class TestPaperSurface extends StatelessWidget {
  const TestPaperSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Theme(data: AppTheme.light(), child: child);
}

@Preview(name: 'Test paper canvas', size: Size(760, 680))
@Preview(name: 'Test paper canvas - Phone', size: Size(390, 680))
Widget testPaperSurfacePreview() => MaterialApp(
  theme: ThemeData.light().copyWith(extensions: const [AppColors.light]),
  home: Scaffold(
    body: TestPaperSurface(
      child: ListView(
        padding: const EdgeInsets.all(32),
        children: const [
          Text('Algebra test', style: TextStyle(fontSize: 28)),
          SizedBox(height: 32),
          Text('Question 1 · 2 points'),
          Text('What is 2 + 2?'),
          SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: 'A',
            onChanged: previewTestChoice,
            child: Column(
              children: [
                RadioListTile(value: 'A', title: Text('A. 4')),
                RadioListTile(value: 'B', title: Text('B. 5')),
              ],
            ),
          ),
          Divider(height: 40),
          Text('Question 2 · 10 points'),
          Text('Show your working on the paper below.'),
        ],
      ),
    ),
  ),
);

void previewTestChoice(String? _) {}
