import 'package:flutter/material.dart';

class TranscriptBox extends StatelessWidget {
  const TranscriptBox({
    super.key,
    required this.text,
    this.placeholder = '(Recognition text will appear here)',
  });

  final String text;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade600),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade900,
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text.isEmpty ? placeholder : text,
          style: const TextStyle(fontSize: 16, height: 1.4),
        ),
      ),
    );
  }
}
