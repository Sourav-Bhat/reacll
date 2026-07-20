import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/import_service.dart';
import '../services/transcription_service.dart';
import 'add_screen.dart';
import 'attach_picker.dart';
import 'home_screen.dart';
import 'people_screen.dart';
import 'record_screen.dart';
import 'tag_screen.dart';

/// Bottom shell: Talks · People · Add — plus the recording FAB.
/// Mirrors the approved prototype exactly.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  StreamSubscription<IncomingItem>? _shareSub;

  @override
  void initState() {
    super.initState();
    // Share-sheet arrivals -> new-vs-existing picker -> tag flow (FR-2/3/4).
    _shareSub = ImportService.instance.incoming.listen(_onIncoming);
  }

  Future<void> _onIncoming(IncomingItem item) async {
    if (!mounted) return;
    final existingId = await showAttachPicker(context, db);
    if (!mounted) return;
    final (convId, needsTranscription) =
        ImportService.instance.attach(db, item, conversationId: existingId);
    if (needsTranscription) {
      // ignore: unawaited_futures
      TranscriptionService.instance.pump(db);
    }
    if (existingId == null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TagScreen(conversationId: convId),
      ));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RecordScreen()),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onChanged: () => setState(() {})),
      PeopleScreen(onChanged: () => setState(() {})),
      AddScreen(onImported: () => setState(() {})),
    ];
    return Scaffold(
      body: pages[_tab],
      floatingActionButton: _tab == 2
          ? null
          : FloatingActionButton.large(
              onPressed: _startRecording,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              child: const Icon(Icons.mic, size: 32),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Talks'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'People'),
          NavigationDestination(
              icon: Icon(Icons.add_circle_outline),
              selectedIcon: Icon(Icons.add_circle),
              label: 'Add'),
        ],
      ),
    );
  }
}
