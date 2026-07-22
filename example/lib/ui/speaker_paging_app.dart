import 'package:flutter/material.dart';

import 'continuous_speaker_paging_page.dart';
import 'multi_speaker_paging_page.dart';
import 'speaker_paging_page.dart';

class SpeakerPagingApp extends StatelessWidget {
  const SpeakerPagingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SIP Speaker Control',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2563eb)),
        useMaterial3: true,
      ),
      home: const ContinuousSpeakerPagingPage(),
      routes: {
        TimedSpeakerPagingPage.routeName: (_) => const SpeakerPagingPage(),
        MultiSpeakerPagingPage.routeName: (_) => const MultiSpeakerPagingPage(),
      },
    );
  }
}

class TimedSpeakerPagingPage {
  static const routeName = '/timed-paging';
}
