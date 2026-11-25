class AssistantEmail {
  const AssistantEmail({
    required this.to,
    required this.subject,
    required this.body,
  });

  final String to;
  final String subject;
  final String body;

  static final _address = RegExp(
    r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$",
  );

  static bool isAddress(String text) =>
      text.length <= 254 && _address.hasMatch(text);

  Map<String, String> toJson() => {'to': to, 'subject': subject, 'body': body};
}

/// Extracts only the recipient and wording explicitly supplied by the user.
/// The review form asks for an exact address when the user gives only a name.
class EmailRequest {
  const EmailRequest({
    this.recipient = '',
    this.subject = '',
    this.message = '',
  });

  final String recipient;
  final String subject;
  final String message;

  static final _command = RegExp(
    r'^(?:please\s+|(?:can|could|would) you\s+)?(?:(?:send|write|draft|compose)\s+(?:(?:an?|the)\s+)?(?:e-?mail|message)\b(?:\s+to\b)?|e-?mail\s+to\b|e-?mail\s+(?=\S+@|.*\b(?:saying|that|about)\b))\s*',
    caseSensitive: false,
  );
  static final _content = RegExp(
    r'\s+(saying|that|about)\s+|:\s+',
    caseSensitive: false,
  );

  static EmailRequest? fromPrompt(String prompt) {
    final text = prompt.trim();
    final command = _command.firstMatch(text);
    if (command == null) return null;
    final rest = text.substring(command.end).trim();
    final divider = _content.firstMatch(rest);
    if (divider == null) return EmailRequest(recipient: rest);
    final recipient = rest.substring(0, divider.start).trim();
    final wording = rest.substring(divider.end).trim();
    return divider.group(1)?.toLowerCase() == 'about'
        ? EmailRequest(recipient: recipient, subject: wording)
        : EmailRequest(recipient: recipient, message: wording);
  }
}

class AssistantEmailReceipt {
  const AssistantEmailReceipt({required this.to, this.demo = false});
  final String to;
  final bool demo;

  String get message =>
      demo ? 'Demo complete. No email was sent.' : 'Email sent to $to.';
}
