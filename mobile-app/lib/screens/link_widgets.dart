// Widgets that connect the StatusStrip to the live GlassesLink.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../components/status_strip.dart';
import '../eyes/phone_eyes.dart';
import '../net/glasses_link.dart';
import '../theme/theme.dart';
import 'front_camera_card.dart';

/// StatusStrip fed by the live link. Ticks once a second while the link is
/// lost so "Link lost 12 s ago" stays current.
class LiveStatusStrip extends StatefulWidget {
  const LiveStatusStrip({super.key, this.bannerOnly = false});

  /// Show nothing while connected (used at the top of tabs other than Today).
  final bool bannerOnly;

  @override
  State<LiveStatusStrip> createState() => _LiveStatusStripState();
}

class _LiveStatusStripState extends State<LiveStatusStrip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = context.watch<GlassesLink>();
    final lost = link.status == LinkStatus.lost;
    if (lost && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!lost && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
    if (widget.bannerOnly && link.status == LinkStatus.connected) return const SizedBox.shrink();
    final connected = link.status == LinkStatus.connected;
    // Today: what the front camera sees, while it streams. With the back camera away it takes
    // the banner's place (and says rear alerts are off); other tabs keep the banner.
    final front = !widget.bannerOnly && _frontOnline(context);
    if (front && !connected) return const FrontCameraCard(rearConnected: false);

    final last = link.lastHeardAt;
    final strip = StatusStrip(
      status: link.status,
      batteryPercent: link.batteryPercent,
      lostFor: lost && last != null ? DateTime.now().difference(last) : null,
    );
    if (!front) return strip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        strip,
        SizedBox(height: context.space.cardGap),
        const FrontCameraCard(rearConnected: true),
      ],
    );
  }
}

bool _frontOnline(BuildContext context) {
  try {
    return context.watch<PhoneEyes>().frontOnline;
  } on ProviderNotFoundException {
    return false;
  }
}

/// Announces connection changes on every tab (screen reader + haptic).
class LinkAnnouncer extends StatefulWidget {
  const LinkAnnouncer({super.key, required this.child});

  final Widget child;

  @override
  State<LinkAnnouncer> createState() => _LinkAnnouncerState();
}

class _LinkAnnouncerState extends State<LinkAnnouncer> {
  late final GlassesLink _link = context.read<GlassesLink>();
  late LinkStatus _last = _link.status;

  @override
  void initState() {
    super.initState();
    _link.addListener(_onChange);
  }

  void _onChange() {
    final now = _link.status;
    if (now == _last || !mounted) return;
    _last = now;
    if (now == LinkStatus.connected) {
      announce(context, 'Glasses connected.');
      HapticFeedback.lightImpact();
    } else if (now == LinkStatus.lost) {
      announce(context, 'Glasses not watching. Link lost.', assertive: true);
      HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _link.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
