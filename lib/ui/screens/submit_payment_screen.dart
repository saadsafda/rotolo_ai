import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../core/money.dart';
import '../../models/payloads.dart';
import '../../models/payment.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets/kit.dart';

final _refPattern = RegExp(r'^[A-Z0-9._/-]{3,100}$');
const _maxMinor = 5000000; // $50,000.00, same limit as the backend

class SubmitPaymentScreen extends ConsumerStatefulWidget {
  const SubmitPaymentScreen({super.key, this.leaseId});
  final String? leaseId;
  @override
  ConsumerState<SubmitPaymentScreen> createState() => _SubmitPaymentScreenState();
}

class _SubmitPaymentScreenState extends ConsumerState<SubmitPaymentScreen> {
  // One key per opened form: retries and double taps replay the same submission.
  String _key = const Uuid().v4();
  int _step = 1;
  String? _property;
  String? _leaseId;
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _date;
  PaymentMethod? _method;
  bool _confirmed = false;
  bool _submitting = false;
  bool _pickingReceipt = false;
  PaymentReceipt? _receipt;
  String? _submitError;
  Map<String, String> _errors = {};
  PaymentSubmission? _result;
  bool _prefilled = false;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  DateTime get _today => businessDay(ref.read(clockProvider)(), ref.read(repositoryProvider).businessTimezone);

  List<Lease> _leases(RentPayload? rent) => (rent?.leases ?? const <Lease>[]).where((l) => l.isActive).toList();

  Lease? _lease(RentPayload? rent) {
    for (final l in rent?.leases ?? const <Lease>[]) {
      if (l.leaseId == _leaseId) return l;
    }
    return null;
  }

  void _prefill(RentPayload? rent) {
    if (_prefilled) return;
    _prefilled = true;
    _date = _today;
    final id = widget.leaseId;
    if (id == null) return;
    for (final l in _leases(rent)) {
      if (l.leaseId == id) {
        _leaseId = l.leaseId;
        _property = l.propertyName;
        _step = 2;
      }
    }
  }

  bool _validate(int step) {
    final e = <String, String>{};
    if (step == 1 && _leaseId == null) e['lease'] = 'Choose the unit and lease this payment applies to.';
    if (step == 2) {
      final minor = parseAmountToMinor(_amount.text);
      if (_amount.text.trim().isEmpty) {
        e['amount'] = 'Enter the amount received.';
      } else if (minor == null) {
        e['amount'] = 'Use digits with up to 2 decimals, e.g. 1,250.00';
      } else if (minor <= 0) {
        e['amount'] = 'Amount must be greater than zero.';
      } else if (minor > _maxMinor) {
        e['amount'] = r'Amounts over $50,000.00 cannot be submitted here.';
      }
      if (_date == null) {
        e['date'] = 'Enter the date the tenant paid.';
      } else if (_date!.isAfter(_today)) {
        e['date'] = 'Payment date cannot be in the future.';
      } else if (_date!.isBefore(_today.subtract(const Duration(days: 90)))) {
        e['date'] = 'Payment date must be within the last 90 days.';
      }
      if (_method == null) e['method'] = 'Choose how the tenant paid.';
    }
    if (step == 3) {
      final ref = _reference.text.trim().toUpperCase();
      if (ref.isEmpty) {
        e['ref'] = 'Enter the transaction, check or receipt number. Required for every method so duplicates can be caught.';
      } else if (!_refPattern.hasMatch(ref)) {
        e['ref'] = 'Use 3–100 letters, digits or . _ / -';
      }
    }
    setState(() => _errors = e);
    return e.isEmpty;
  }

  void _next() {
    FocusScope.of(context).unfocus();
    if (_validate(_step)) setState(() => _step++);
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_step > 1) {
      setState(() {
        _step--;
        _errors = {};
      });
    } else {
      _close();
    }
  }

  void _close() => context.canPop() ? context.pop() : context.go('/payments');

  Future<void> _pickReceipt() async {
    if (_pickingReceipt) return;
    setState(() => _pickingReceipt = true);
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
      if (file == null || !mounted) return;
      if (await file.length() > PaymentReceipt.maxBytes) {
        throw const PaymentRuleException('Choose an image under 5 MB.');
      }
      final receipt = PaymentReceipt(await file.readAsBytes());
      if (mounted) setState(() => _receipt = receipt);
    } on PaymentRuleException catch (error) {
      if (mounted) showToast(context, error.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not select a receipt image.');
    } finally {
      if (mounted) setState(() => _pickingReceipt = false);
    }
  }

  Future<void> _submit(RentPayload? rent) async {
    if (_submitting || !_confirmed) return;
    final lease = _lease(rent);
    final minor = parseAmountToMinor(_amount.text);
    if (lease == null || minor == null || _method == null || _date == null) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final notes = _notes.text.trim();
      final sub = await ref.read(repositoryProvider).submitPayment(PaymentDraft(
            idempotencyKey: _key,
            leaseId: lease.leaseId,
            amountMinor: minor,
            paymentDate: _date!,
            method: _method!,
            reference: _reference.text,
            fundsConfirmed: _confirmed,
            propertyId: lease.propertyId,
            propertyName: lease.propertyName,
            unit: lease.unit,
            tenantName: lease.tenants?.join(', ') ?? lease.leaseName,
            notes: notes.isEmpty ? null : notes,
          ), receipt: _receipt);
      ref.read(dataVersionProvider.notifier).bump();
      if (mounted) setState(() => _result = sub);
    } on PaymentRuleException catch (e) {
      if (mounted) setState(() => _submitError = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _another() => setState(() {
        _key = const Uuid().v4();
        _step = 1;
        _property = null;
        _leaseId = null;
        _amount.clear();
        _reference.clear();
        _notes.clear();
        _receipt = null;
        _date = _today;
        _method = null;
        _confirmed = false;
        _result = null;
        _errors = {};
      });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final snap = ref.watch(snapshotProvider);
    return Scaffold(
      backgroundColor: t.bg,
      body: Column(children: [
        const DemoStrip(),
        Expanded(
          child: AsyncBody(
            value: snap,
            builder: (s) {
              final rent = s.rent;
              _prefill(rent);
              if (_result != null) return _success(_result!);
              return Column(children: [
                DetailHeader(
                  title: 'Outside payment',
                  leadingIcon: Icons.close_rounded,
                  onBack: _close,
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('Step $_step of 4', style: TextStyle(fontSize: 13, color: t.mu)),
                  ),
                ),
                Padding(
                  padding: pagePad,
                  child: Row(children: [
                    for (var i = 1; i <= 4; i++) ...[
                      if (i > 1) const SizedBox(width: 6),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(color: i <= _step ? t.ac : t.bd, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ],
                  ]),
                ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
                    Text(const ['', 'Which lease?', 'Payment details', 'Evidence', 'Review and submit'][_step],
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 18),
                    ...switch (_step) {
                      1 => _stepLease(rent),
                      2 => _stepDetails(rent),
                      3 => _stepEvidence(),
                      _ => _stepReview(s, rent),
                    },
                  ]),
                ),
                StickyBar(
                  child: Row(children: [
                    Expanded(child: OutlinedButton(onPressed: _back, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)), child: const Text('Back'))),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _step < 4
                          ? FilledButton(key: const ValueKey('wizard-next'), onPressed: _next, child: const Text('Continue'))
                          : FilledButton(
                              key: const ValueKey('submit-payment'),
                              onPressed: _confirmed && !_submitting ? () => _submit(rent) : null,
                              child: Text(_submitting ? 'Submitting…' : 'Submit for review'),
                            ),
                    ),
                  ]),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Widget _label(String s, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: s, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (hint != null) TextSpan(text: ' $hint', style: TextStyle(color: context.t.mu)),
        ]), style: const TextStyle(fontSize: 14)),
      );

  Widget _error(String key) => _errors[key] == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.error_outline_rounded, size: 16, color: context.t.er),
            const SizedBox(width: 6),
            Expanded(child: Text(_errors[key]!, style: TextStyle(fontSize: 13, color: context.t.er))),
          ]),
        );

  List<Widget> _stepLease(RentPayload? rent) {
    final t = context.t;
    final leases = _leases(rent);
    if (rent == null || leases.isEmpty) {
      return [const NoticeBox(tone: Tone.wa, icon: Icons.cloud_off_outlined, text: 'No active DoorLoop leases are available in the latest report.')];
    }
    final props = {for (final l in leases) l.propertyName}.toList()..sort();
    return [
      _label('Property'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in props)
          SelectChip(
            label: p,
            selected: _property == p,
            radius: 12,
            height: 44,
            onTap: () => setState(() {
              _property = p;
              _leaseId = null;
              _errors = {};
            }),
          ),
      ]),
      if (_property != null) ...[
        const SizedBox(height: 16),
        _label('Unit and lease'),
        for (final l in leases.where((l) => l.propertyName == _property)) ...[
          Material(
            color: _leaseId == l.leaseId ? t.acs : t.sf,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14), side: BorderSide(color: _leaseId == l.leaseId ? t.ac : t.bd)),
            child: InkWell(
              customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () => setState(() {
                _leaseId = l.leaseId;
                _errors = {};
              }),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    Icon(_leaseId == l.leaseId ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                        size: 22, color: _leaseId == l.leaseId ? t.ac : t.mu),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${l.unit == null ? 'Whole property' : 'Unit ${l.unit}'} · ${LeaseView(l).tenant}',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('Lease ${l.reference ?? l.leaseId} · active', style: TextStyle(fontSize: 13, color: t.mu)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
      _error('lease'),
    ];
  }

  List<Widget> _stepDetails(RentPayload? rent) {
    final t = context.t;
    final lease = _lease(rent);
    return [
      if (lease != null)
        Text('Lease ${lease.reference ?? lease.leaseId} · ${LeaseView(lease).tenant} · ${LeaseView(lease).title}',
            style: TextStyle(fontSize: 13, color: t.mu)),
      const SizedBox(height: 16),
      _label('Amount received'),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() => _errors.remove('amount')),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFeatures: tabular),
            decoration: InputDecoration(
              hintText: '0.00',
              prefixText: r'$ ',
              prefixStyle: TextStyle(fontSize: 17, color: t.mu),
              errorText: _errors['amount'] == null ? null : '',
              errorStyle: const TextStyle(height: 0, fontSize: 0),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 96,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: t.sf2, border: Border.all(color: t.bd), borderRadius: BorderRadius.circular(12)),
          child: Tooltip(message: 'Only USD is supported', child: Text('USD', style: TextStyle(fontSize: 15, color: t.mu))),
        ),
      ]),
      _error('amount'),
      const SizedBox(height: 16),
      _label('Payment date'),
      Material(
        color: t.sf,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: BorderSide(color: _errors['date'] == null ? t.bd : t.er)),
        child: InkWell(
          key: const ValueKey('payment-date'),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _date ?? _today,
              firstDate: _today.subtract(const Duration(days: 90)),
              lastDate: _today,
            );
            if (picked != null) {
              setState(() {
                _date = picked;
                _errors.remove('date');
              });
            }
          },
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Expanded(child: Text(_date == null ? 'Select date' : fullDate(_date!), style: const TextStyle(fontSize: 15))),
                Icon(Icons.calendar_today_outlined, size: 18, color: t.mu),
              ]),
            ),
          ),
        ),
      ),
      _error('date'),
      const SizedBox(height: 16),
      _label('Method'),
      LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 16) / 3;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in PaymentMethod.values)
            SizedBox(
              width: w,
              child: SelectChip(
                label: m.label,
                selected: _method == m,
                radius: 12,
                height: 48,
                wrap: true,
                onTap: () => setState(() {
                  _method = m;
                  _errors.remove('method');
                }),
              ),
            ),
        ]);
      }),
      _error('method'),
    ];
  }

  List<Widget> _stepEvidence() {
    final t = context.t;
    final label = switch (_method) {
      PaymentMethod.check || PaymentMethod.cashiersCheck => 'Check number',
      PaymentMethod.cash => 'Receipt number',
      PaymentMethod.moneyOrder => 'Money order number',
      _ => 'Transaction or reference number',
    };
    return [
      _label(label),
      TextField(
        key: const ValueKey('reference'),
        controller: _reference,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        onChanged: (_) => setState(() => _errors.remove('ref')),
        style: const TextStyle(fontFamily: kMono, fontSize: 15),
        decoration: InputDecoration(
          hintText: 'e.g. ZL-88213-QK',
          errorText: _errors['ref'] == null ? null : '',
          errorStyle: const TextStyle(height: 0, fontSize: 0),
        ),
      ),
      _error('ref'),
      const SizedBox(height: 16),
      _label('Receipt'),
      if (ref.watch(repositoryProvider).isSynthetic)
        const Text('Receipt attachments are available in live mode.')
      else
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _pickingReceipt ? null : _pickReceipt,
            icon: const Icon(Icons.attach_file),
            label: Text(_receipt == null ? 'Attach image' : 'Replace image'),
          ),
          if (_receipt != null)
            TextButton(onPressed: () => setState(() => _receipt = null), child: const Text('Remove image')),
        ]),
      const SizedBox(height: 8),
      Text('JPEG or PNG, up to 5 MB. Receipts are stored privately for payment review.',
          style: TextStyle(fontSize: 13, height: 1.45, color: t.mu)),
      const SizedBox(height: 16),
      _label('Notes', hint: '(optional)'),
      TextField(
        controller: _notes,
        maxLines: 3,
        maxLength: 1000,
        style: const TextStyle(fontSize: 15),
        decoration: const InputDecoration(hintText: 'Context for the reviewer'),
      ),
    ];
  }

  List<Widget> _stepReview(Snapshot s, RentPayload? rent) {
    final t = context.t;
    final lease = _lease(rent);
    final minor = parseAmountToMinor(_amount.text);
    final dup = lease == null || minor == null
        ? null
        : duplicateFor(leaseId: lease.leaseId, amountMinor: minor, paymentDate: _date, submissions: s.payments, rent: rent);
    final rows = <(String, String, int)>[
      ('Property and unit', lease == null ? '—' : LeaseView(lease).title, 1),
      ('Lease', lease == null ? '—' : '${lease.reference ?? lease.leaseId} · ${LeaseView(lease).tenant}', 1),
      ('Amount', minor == null ? '—' : '${Money(minor).format()} USD', 2),
      ('Payment date', _date == null ? '—' : fullDate(_date!), 2),
      ('Method', _method?.label ?? '—', 2),
      ('Reference', _reference.text.trim().toUpperCase(), 3),
      ('Receipt', _receipt == null ? 'Not attached' : 'Image attached', 3),
      ('Notes', _notes.text.trim().isEmpty ? 'None' : _notes.text.trim(), 3),
    ];
    return [
      if (dup != null) ...[
        NoticeBox(
          tone: Tone.wa,
          icon: Icons.content_copy_rounded,
          title: 'Possible duplicate.',
          text: '${dup.why} ${dup.what}. You can still submit; the reviewer will see this warning.',
        ),
        const SizedBox(height: 14),
      ],
      SurfaceCard(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.bd),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Row(children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(rows[i].$1, style: TextStyle(fontSize: 12, color: t.mu)),
                      Text(rows[i].$2,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, fontFamily: rows[i].$1 == 'Reference' ? kMono : null)),
                    ]),
                  ),
                ),
                TextButton(onPressed: () => setState(() => _step = rows[i].$3), child: const Text('Edit')),
              ]),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      Material(
        color: t.sf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: _confirmed ? t.ac : t.bd)),
        child: CheckboxListTile(
          key: const ValueKey('funds-confirm'),
          value: _confirmed,
          onChanged: (v) => setState(() => _confirmed = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('I confirm these funds were actually received', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('A screenshot or tenant message alone is not proof of payment.', style: TextStyle(fontSize: 12, color: t.mu)),
        ),
      ),
      const SizedBox(height: 14),
      const NoticeBox(
        tone: Tone.ac,
        icon: Icons.info_outline_rounded,
        text: 'Submitting creates a review request for the owner. It does not record a payment in DoorLoop.',
      ),
      if (_submitError != null) ...[
        const SizedBox(height: 14),
        NoticeBox(tone: Tone.er, icon: Icons.error_outline_rounded, text: _submitError!),
      ],
    ];
  }

  Widget _success(PaymentSubmission p) {
    final t = context.t;
    return ListView(padding: const EdgeInsets.fromLTRB(24, 64, 24, 32), children: [
      Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: t.oks, borderRadius: BorderRadius.circular(36)),
          child: Icon(Icons.check_rounded, size: 40, color: t.ok),
        ),
      ),
      const SizedBox(height: 16),
      const Text('Review request submitted', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      const SizedBox(height: 16),
      Text('${displayId(p.id)} · ${Money(p.draft.amountMinor).format()}', textAlign: TextAlign.center, style: mono(context, size: 15)),
      const SizedBox(height: 16),
      Text(
        'The owner will review it. Nothing has been recorded in DoorLoop. You will see the status change here when it is approved.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, height: 1.5, color: t.mu),
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: () => context.go('/payments/${p.id}'), child: const Text('View request')),
      const SizedBox(height: 10),
      OutlinedButton(onPressed: _another, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)), child: const Text('Submit another')),
    ]);
  }
}
