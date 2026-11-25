import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/assistant.dart';
import '../../models/assistant_email.dart';

class AssistantEmailSheet extends StatefulWidget {
  const AssistantEmailSheet({
    super.key,
    required this.request,
    required this.from,
    required this.demo,
    required this.onSend,
  });

  final EmailRequest request;
  final String from;
  final bool demo;
  final Future<AssistantEmailReceipt> Function(AssistantEmail, String) onSend;

  @override
  State<AssistantEmailSheet> createState() => _AssistantEmailSheetState();
}

class _AssistantEmailSheetState extends State<AssistantEmailSheet> {
  late final _address = TextEditingController(
    text: AssistantEmail.isAddress(widget.request.recipient)
        ? widget.request.recipient
        : '',
  );
  late final _subject = TextEditingController(text: widget.request.subject);
  late final _body = TextEditingController(text: widget.request.message);
  final _form = GlobalKey<FormState>();
  String? _error;
  String? _requestId;
  bool _sending = false;

  @override
  void dispose() {
    _address.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || !_form.currentState!.validate()) return;
    final email = AssistantEmail(
      to: _address.text.trim(),
      subject: _subject.text.trim(),
      body: _body.text.trim(),
    );
    final requestId = _requestId ??= const Uuid().v4();
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final receipt = await widget.onSend(email, requestId);
      if (mounted) Navigator.of(context).pop(receipt);
    } on AssistantFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.request.recipient;
    final needsAddress = name.isNotEmpty && !AssistantEmail.isAddress(name);
    return PopScope(
      canPop: !_sending,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Form(
            key: _form,
            onChanged: () => _requestId = null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Review email',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close email',
                      onPressed: _sending
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  widget.demo
                      ? 'Demo mode. No email will be sent.'
                      : 'Sending from ${widget.from}',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('email-recipient'),
                  controller: _address,
                  enabled: !_sending,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: 'To',
                    hintText: needsAddress
                        ? 'Email address for $name'
                        : 'Email address',
                  ),
                  validator: (value) =>
                      AssistantEmail.isAddress(value?.trim() ?? '')
                      ? null
                      : 'Enter one email address.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('email-subject'),
                  controller: _subject,
                  enabled: !_sending,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Subject',
                    counterText: '',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a subject.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('email-message'),
                  controller: _body,
                  enabled: !_sending,
                  minLines: 3,
                  maxLines: 7,
                  maxLength: 10000,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    alignLabelWithHint: true,
                    counterText: '',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a message.'
                      : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey('email-confirm'),
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(
                    _sending
                        ? 'Sending…'
                        : widget.demo
                        ? 'Try sending'
                        : 'Send email',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
