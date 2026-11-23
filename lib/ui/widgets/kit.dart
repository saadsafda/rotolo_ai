import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme.dart';

// Building blocks of the "Real Estate AI" design. Spacing 4·8·12·16·20·24·32,
// radius 8/12/16, touch targets ≥ 44 px.

const pagePad = EdgeInsets.symmetric(horizontal: 20);

const _tabRoots = {'/assistant', '/home', '/reports', '/payments', '/tasks', '/more'};

/// Tab roots switch tabs; anything deeper is pushed so Back returns here.
void openRoute(BuildContext context, String route) {
  final path = Uri.parse(route).path;
  if (_tabRoots.contains(path)) {
    context.go(route);
  } else {
    context.push(route);
  }
}

TextStyle mono(BuildContext context, {double size = 13, Color? color}) =>
    TextStyle(fontFamily: kMono, fontSize: size, color: color ?? context.t.tx);

/// White surface card with a hairline border.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap, this.color});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.bd));
    return Material(
      color: color ?? t.sf,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Card whose children are separated by hairlines (key/value lists, menus).
class ListCard extends StatelessWidget {
  const ListCard({super.key, required this.children, this.horizontal = 16, this.title});
  final List<Widget> children;
  final double horizontal;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(title!, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1) Divider(color: t.bd, height: 1),
        ],
      ]),
    );
  }
}

/// Rounded status pill, e.g. "Under review".
class ToneChip extends StatelessWidget {
  const ToneChip(this.label, this.tone, {super.key, this.icon, this.small = false, this.square = false});
  final String label;
  final Tone tone;
  final IconData? icon;
  final bool small;
  final bool square;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = context.t.tone(tone);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 7 : 8, vertical: small ? 2 : 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(square ? 6 : 999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: small ? 11 : 12, fontWeight: FontWeight.w600, color: fg)),
        ),
      ]),
    );
  }
}

/// Bordered badge used for source names ("DoorLoop").
class SourceBadge extends StatelessWidget {
  const SourceBadge(this.label, {super.key, this.icon, this.iconColor, this.small = false});
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      height: small ? 22 : 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: t.sf2, border: Border.all(color: t.bd), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: iconColor ?? t.mu), const SizedBox(width: 4)],
        Text(label,
            style: TextStyle(fontSize: small ? 11 : 12, fontWeight: FontWeight.w600, color: small ? t.mu : t.tx)),
      ]),
    );
  }
}

/// Horizontally scrolling single-select chips (filters).
class ChipRow<T> extends StatelessWidget {
  const ChipRow({super.key, required this.options, required this.selected, required this.onSelected, this.leading});
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final IconData? leading;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: pagePad,
      child: Row(children: [
        for (final (value, label) in options) ...[
          SelectChip(label: label, selected: value == selected, onTap: () => onSelected(value), icon: leading),
          const SizedBox(width: 8),
        ],
      ]),
    );
  }
}

class SelectChip extends StatelessWidget {
  const SelectChip({super.key, required this.label, required this.selected, required this.onTap, this.icon, this.height = 40, this.radius = 999, this.wrap = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final double height;
  final double radius;

  /// Fixed-width grid cells: let long labels wrap onto two lines.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fg = selected ? t.onsel : t.tx;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? t.sel : t.sf,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius), side: BorderSide(color: selected ? t.sel : t.bd)),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: height),
            padding: EdgeInsets.symmetric(horizontal: wrap ? 6 : 14, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
              Flexible(
                child: Text(label,
                    textAlign: TextAlign.center,
                    maxLines: wrap ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: wrap ? 14 : 13, height: 1.15, fontWeight: FontWeight.w500, color: fg)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// iOS-style segmented control on a neutral track.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.selected, required this.onSelected});
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: t.nas, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Builder(builder: (context) {
              final (value, label) = options[i];
              final on = value == selected;
              return Semantics(
                selected: on,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? t.sf : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: on ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                    ),
                    child: Text(label,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? t.tx : t.mu)),
                  ),
                ),
              );
            }),
          ),
        ],
      ]),
    );
  }
}

/// Tinted callout ("Partial report.", "Possible duplicate.").
class NoticeBox extends StatelessWidget {
  const NoticeBox({super.key, required this.tone, required this.icon, required this.text, this.title, this.child});
  final Tone tone;
  final IconData icon;
  final String text;
  final String? title;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (bg, fg) = t.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(
              TextSpan(children: [
                if (title != null) TextSpan(text: '$title ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: text),
              ]),
              style: TextStyle(fontSize: 14, height: 1.45, color: t.tx),
            ),
            if (child != null) ...[const SizedBox(height: 10), child!],
          ]),
        ),
      ]),
    );
  }
}

/// Large tinted panel with a coloured heading (verification, failure, duplicate).
class AlertPanel extends StatelessWidget {
  const AlertPanel({super.key, required this.tone, required this.icon, required this.title, required this.children});
  final Tone tone;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (bg, fg) = t.tone(tone);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 22, color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg))),
        ]),
        for (final c in children) ...[const SizedBox(height: 10), c],
      ]),
    );
  }
}

/// Top bar for drill-down screens: back arrow, title, optional subtitle/trailing.
class DetailHeader extends StatelessWidget {
  const DetailHeader({super.key, required this.title, this.subtitle, this.trailing, this.leadingIcon = Icons.arrow_back_rounded, this.onBack, this.fallback = '/home'});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData leadingIcon;
  final VoidCallback? onBack;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8),
        child: Row(children: [
          IconButton(
            tooltip: leadingIcon == Icons.close_rounded ? 'Close' : 'Back',
            iconSize: 24,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: Icon(leadingIcon, color: t.tx),
            onPressed: onBack ?? () => context.canPop() ? context.pop() : context.go(fallback),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: t.mu)),
            ]),
          ),
          ?trailing,
        ]),
      ),
    );
  }
}

/// Mono ID shown at the right of a detail header.
class HeaderId extends StatelessWidget {
  const HeaderId(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(id, style: mono(context, color: context.t.mu)),
      );
}

/// Headline for tab roots ("Payments").
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.subtitle, this.subtitleWidget, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: pagePad,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -.2)),
            if (subtitle != null || subtitleWidget != null) ...[
              const SizedBox(height: 4),
              subtitleWidget ?? Text(subtitle!, style: TextStyle(fontSize: 13, color: context.t.mu)),
            ],
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.size = 14});
  final String text;
  final Widget? trailing;
  final double size;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600))),
        ?trailing,
      ]);
}

/// Label/value row (min height 52) for detail cards.
class KVRow extends StatelessWidget {
  const KVRow(this.label, this.value, {super.key, this.trailing, this.valueStyle, this.onTap, this.stacked = false});
  final String label;
  final String value;
  final Widget? trailing;
  final TextStyle? valueStyle;
  final VoidCallback? onTap;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final Widget body = stacked
        ? Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 12, color: t.mu)),
                const SizedBox(height: 2),
                Text(value, style: valueStyle ?? const TextStyle(fontSize: 14)),
              ]),
            ),
            ?trailing,
          ])
        : Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: t.mu))),
            const SizedBox(width: 12),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right, style: valueStyle ?? const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ]);
    final padded = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Align(alignment: Alignment.centerLeft, child: body)),
    );
    return onTap == null ? padded : InkWell(onTap: onTap, child: padded);
  }
}

class TimelineEntry {
  const TimelineEntry(this.text, this.when);
  final String text;
  final String when;
}

/// Dotted audit/activity timeline.
class Timeline extends StatelessWidget {
  const Timeline(this.entries, {super.key});
  final List<TimelineEntry> entries;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              margin: const EdgeInsets.only(top: 6, right: 12),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: t.ac, borderRadius: BorderRadius.circular(4)),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.text, style: const TextStyle(fontSize: 14, height: 1.4)),
                Text(e.when, style: TextStyle(fontSize: 12, color: t.mu)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action, this.onAction});
  final IconData icon;
  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(children: [
        Icon(icon, size: 36, color: t.mu),
        const SizedBox(height: 8),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        if (body != null) ...[
          const SizedBox(height: 6),
          Text(body!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: t.mu, height: 1.45)),
        ],
        if (action != null) ...[
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onAction, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)), child: Text(action!)),
        ],
      ]),
    );
  }
}

/// Pulsing grey blocks shown while data loads.
class SkeletonView extends StatefulWidget {
  const SkeletonView({super.key});
  @override
  State<SkeletonView> createState() => _SkeletonViewState();
}

class _SkeletonViewState extends State<SkeletonView> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.t.nas;
    Widget block(double h, {double? w, double r = 16}) =>
        Container(height: h, width: w, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(r)));
    return Semantics(
      label: 'Loading',
      child: FadeTransition(
        opacity: Tween(begin: 1.0, end: .45).animate(_c),
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth.isFinite ? c.maxWidth : 350.0;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              block(28, w: w * .6, r: 8),
              const SizedBox(height: 16),
              block(16, w: w * .4, r: 6),
              const SizedBox(height: 16),
              block(120),
              const SizedBox(height: 16),
              Row(children: [Expanded(child: block(96)), const SizedBox(width: 12), Expanded(child: block(96))]),
              const SizedBox(height: 12),
              Row(children: [Expanded(child: block(96)), const SizedBox(width: 12), Expanded(child: block(96))]),
            ]),
          );
        }),
      ),
    );
  }
}

/// Loading skeleton, readable error, or content.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const SingleChildScrollView(child: SkeletonView()),
        error: (e, _) => EmptyState(icon: Icons.error_outline_rounded, title: 'Could not load', body: e.toString()),
      );
}

/// Dark floating toast with a check icon.
void showToast(BuildContext context, String message, {IconData icon = Icons.check_circle_rounded}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 2800),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Row(children: [
        Icon(icon, size: 20, color: NavColors.toastIcon),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
    ));
}

/// Full-width primary action used in sticky bars.
class BigButton extends StatelessWidget {
  const BigButton({super.key, required this.label, this.onPressed, this.icon, this.color, this.foreground, this.buttonKey});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;
  final Color? foreground;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      backgroundColor: color,
      foregroundColor: foreground,
    );
    return icon == null
        ? FilledButton(key: buttonKey, onPressed: onPressed, style: style, child: Text(label))
        : FilledButton.icon(key: buttonKey, onPressed: onPressed, style: style, icon: Icon(icon, size: 20), label: Text(label));
  }
}

/// Bottom action area pinned above the keyboard/home indicator.
class StickyBar extends StatelessWidget {
  const StickyBar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      decoration: BoxDecoration(color: t.bg, border: Border(top: BorderSide(color: t.bd))),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: SafeArea(top: false, child: child),
    );
  }
}

/// Small leading icon tile (36×36, radius 10) used in lists.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, this.tone, {super.key, this.size = 36});
  final IconData icon;
  final Tone tone;
  final double size;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = context.t.tone(tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size > 38 ? 12 : 10)),
      child: Icon(icon, size: size * .56, color: fg),
    );
  }
}
