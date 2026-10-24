// Settings and privacy. Phase 1 step 1: device info and the Widget Gallery.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../gallery/widget_gallery.dart';
import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../theme/theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = context.watch<GlassesLink>();
    final status = switch (link.status) {
      LinkStatus.searching => 'Not connected yet',
      LinkStatus.connected => 'Connected',
      LinkStatus.lost => 'Link lost',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _Header('Device'),
          ListTile(
            leading: const Icon(Symbols.eyeglasses_rounded),
            title: const Text('Glasses'),
            subtitle: Text('$status · frame ${link.frame ?? 'not found'}'),
          ),
          ListTile(
            leading: const Icon(Symbols.videocam_rounded),
            title: const Text('Rear camera'),
            subtitle: Text(link.streamUrl?.toString() ?? 'Not found'),
          ),
          ListTile(
            leading: const Icon(Symbols.motion_sensor_active_rounded),
            title: const Text('Reflex camera'),
            subtitle: Text(link.camBStreamUrl?.toString() ?? 'Not found'),
          ),
          ListTile(
            leading: const Icon(Symbols.wifi_tethering_rounded),
            title: const Text('How pairing works'),
            subtitle: Text(
              "Turn on your phone's hotspot. The glasses join it and say hello to "
              'this app on UDP port $appUdpPort. No venue Wi-Fi needed.',
            ),
          ),
          _Header('Privacy'),
          const ListTile(
            leading: Icon(Symbols.videocam_off_rounded),
            title: Text('Nothing recorded'),
            subtitle: Text('Video and audio are processed on this phone and thrown away. No faces or names.'),
          ),
          const ListTile(
            leading: Icon(Symbols.lock_rounded),
            title: Text('Friends see your ring % only'),
            subtitle: Text('Sensor data stays on this phone.'),
          ),
          if (kDebugMode) ...[
            _Header('Developer'),
            ListTile(
              leading: const Icon(Symbols.palette_rounded),
              title: const Text('Widget Gallery'),
              subtitle: const Text('Every component in light, dark and 200% text'),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: () => Navigator.of(context).pushNamed(WidgetGallery.route),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(context.space.l, context.space.xl, context.space.l, context.space.s),
      child: Semantics(header: true, child: Text(text, style: context.type.headline)),
    );
  }
}
