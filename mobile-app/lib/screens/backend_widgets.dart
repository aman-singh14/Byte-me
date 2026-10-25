// Shared pieces for screens that show eye, near-work and ring data (from the
// phone itself, or a laptop backend).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../net/backend_link.dart';
import '../theme/theme.dart';

/// The BackendLink if one is provided above (screens still lay out without it).
BackendLink? watchBackend(BuildContext context) {
  try {
    return context.watch<BackendLink>();
  } on ProviderNotFoundException {
    return null;
  }
}

BackendLink? readBackend(BuildContext context) {
  try {
    return context.read<BackendLink>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// One line on why there is no data yet, or null when data is flowing.
String? backendProblem(BackendLink? link) {
  if (link == null) return 'Not connected to the laptop.';
  return switch (link.status) {
    BackendStatus.notConfigured => 'Waiting for the laptop. Set its address in Settings if this persists.',
    BackendStatus.connecting => 'Connecting to the laptop…',
    BackendStatus.unreachable => "Can't reach the laptop at ${link.baseUrl?.authority}. ${link.lastError ?? ''}".trim(),
    BackendStatus.connected => null,
  };
}

/// Muted explanatory line used inside cards.
class NoteText extends StatelessWidget {
  const NoteText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.type.body.copyWith(color: context.colors.textSecondary));
}

IconData iconForNearWork(String? kind) => switch (kind) {
  'phone' => Symbols.smartphone_rounded,
  'laptop' => Symbols.laptop_rounded,
  'tv' => Symbols.tv_rounded,
  'keyboard' => Symbols.keyboard_rounded,
  'book' => Symbols.menu_book_rounded,
  _ => Symbols.devices_rounded,
};

/// "phone" -> "Phone", "tv" -> "TV".
String nearWorkName(String? kind) => kind == 'tv' ? 'TV' : capitalize(kind ?? 'screen');

/// Settings row: the backend address, where it came from, and whether it answers.
class BackendSettingsTile extends StatelessWidget {
  const BackendSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    if (link == null) return const SizedBox.shrink();
    final base = link.baseUrl;
    final source = link.manualUrl != null ? 'typed in' : (link.discoveredUrl != null ? 'found automatically' : null);
    final status = link.onPhone
        ? 'Not needed: eyes, near-work and rings run on this phone'
        : switch (link.status) {
            BackendStatus.notConfigured => 'Not set',
            BackendStatus.connecting => 'Connecting',
            BackendStatus.connected => 'Connected',
            BackendStatus.unreachable => 'Not answering',
          };
    return ListTile(
      leading: const Icon(Symbols.laptop_mac_rounded),
      title: const Text('Laptop (optional)'),
      subtitle: Text(base == null ? status : '$status · ${base.authority}${source == null ? '' : ' ($source)'}'),
      trailing: const Icon(Symbols.edit_rounded),
      onTap: () => _edit(context, link),
    );
  }

  Future<void> _edit(BuildContext context, BackendLink link) async {
    final controller = TextEditingController(text: link.manualUrl?.authority ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Laptop address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "The laptop's IP on the hotspot, e.g. 172.20.10.2, to run eye tracking there instead. Leave "
              'empty to use this phone, or a laptop that says hello'
              '${link.discoveredUrl != null ? ' (now ${link.discoveredUrl!.authority})' : ''}.',
            ),
            SizedBox(height: context.space.m),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Address', hintText: '172.20.10.2:8001'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result == null || !context.mounted) return;
    final ok = await link.setManualUrl(result);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That doesn't look like an address.")));
    }
  }
}

/// Developer section (debug builds): force the outdoor detector on or off.
class DevOutsideTile extends StatefulWidget {
  const DevOutsideTile({super.key});

  @override
  State<DevOutsideTile> createState() => _DevOutsideTileState();
}

class _DevOutsideTileState extends State<DevOutsideTile> {
  bool? _value; // null = automatic

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    if (link == null || !kDebugMode) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Symbols.sunny_rounded),
      title: const Text('Outside (debug)'),
      subtitle: Padding(
        padding: EdgeInsets.only(top: context.space.s),
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Auto')),
            ButtonSegment(value: 1, label: Text('Outside')),
            ButtonSegment(value: 2, label: Text('Inside')),
          ],
          selected: {_value == null ? 0 : (_value! ? 1 : 2)},
          onSelectionChanged: (s) async {
            final v = switch (s.first) {
              1 => true,
              2 => false,
              _ => null,
            };
            final err = await link.setOutside(v);
            if (!context.mounted) return;
            if (err != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
            } else {
              setState(() => _value = v);
            }
          },
        ),
      ),
    );
  }
}
