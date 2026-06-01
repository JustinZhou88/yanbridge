import 'package:flutter/material.dart';
import 'pages/realtime_asr_page.dart';

void main() {
  runApp(const YanBridgeApp());
}

class YanBridgeApp extends StatelessWidget {
  const YanBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'YanBridge Realtime ASR',
      theme: ThemeData.dark(),
      home: const RealtimeASRPage(),
    );
  }
}
