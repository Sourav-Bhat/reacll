import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../services/ask_service.dart';
import 'detail_screen.dart';

class AskScreen extends StatefulWidget {
  const AskScreen({super.key});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _Msg {
  final bool me;
  final String text;
  final List<AskCitation> cites;
  _Msg(this.me, this.text, [this.cites = const []]);
}

class _AskScreenState extends State<AskScreen> {
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  bool _loading = false;

  static const _suggestions = [
    'What did I discuss with Andy?',
    'What do I owe people right now?',
    'What decisions were made about ESG?',
  ];

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final q = (preset ?? _ctl.text).trim();
    if (q.isEmpty || _loading) return;
    setState(() {
      _msgs.add(_Msg(true, q));
      _loading = true;
      _ctl.clear();
    });
    _scrollDown();
    try {
      final r = await AskService.instance.ask(db, q);
      setState(() {
        _msgs.add(_Msg(false, r.answer, r.citations));
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _msgs.add(_Msg(false, "Couldn't answer — $e"));
        _loading = false;
      });
    }
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ask your memory', style: t.textTheme.headlineMedium),
                Text('Grounded in your conversations — with citations.',
                    style: t.textTheme.bodyMedium
                        ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: _msgs.isEmpty
                ? _empty(t)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                    itemCount: _msgs.length + (_loading ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _msgs.length) return _typing(t);
                      return _bubble(t, _msgs[i]);
                    },
                  ),
          ),
          _inputBar(t),
        ],
      ),
    );
  }

  Widget _empty(ThemeData t) => ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
        children: [
          Icon(Icons.auto_awesome,
              size: 40, color: t.colorScheme.primary.withValues(alpha: .5)),
          const SizedBox(height: 12),
          Text('Ask anything about the people and conversations you\'ve captured.',
              style: t.textTheme.bodyLarge?.copyWith(height: 1.5)),
          const SizedBox(height: 18),
          ..._suggestions.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: OutlinedButton(
                  onPressed: () => _send(s),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(s, textAlign: TextAlign.left),
                ),
              )),
        ],
      );

  Widget _bubble(ThemeData t, _Msg m) {
    return Align(
      alignment: m.me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: m.me ? t.colorScheme.primary : t.colorScheme.surface,
          border: m.me ? null : Border.all(color: t.colorScheme.outlineVariant),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.me ? 18 : 5),
            bottomRight: Radius.circular(m.me ? 5 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.text,
                style: t.textTheme.bodyMedium?.copyWith(
                    height: 1.5,
                    color: m.me ? Colors.white : t.colorScheme.onSurface)),
            if (m.cites.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: m.cites
                      .map((c) => GestureDetector(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => DetailScreen(
                                        conversationId: c.conversationId))),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(
                                  color: const Color(0xFFE6EDE2),
                                  borderRadius: BorderRadius.circular(10)),
                              child: Text(
                                '${c.title} · ${DateFormat('d MMM').format(c.happenedAt)}',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF4E6B4A)),
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _typing(ThemeData t) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: t.colorScheme.surface,
              border: Border.all(color: t.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(16)),
          child: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2)),
        ),
      );

  Widget _inputBar(ThemeData t) => Padding(
        padding: EdgeInsets.fromLTRB(
            14, 6, 14, MediaQuery.of(context).viewInsets.bottom + 10),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Ask about your conversations…',
                filled: true,
                fillColor: t.colorScheme.surface,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: t.colorScheme.outlineVariant)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: t.colorScheme.outlineVariant)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            onPressed: _loading ? null : () => _send(),
            elevation: 0,
            child: const Icon(Icons.arrow_upward),
          ),
        ]),
      );
}
