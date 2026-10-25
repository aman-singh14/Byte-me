// Settings and privacy. Phase 1 step 1: device info and the Widget Gallery.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../alerts/voice.dart';
import '../eyes/gaze.dart' show gazePrompt;
import '../eyes/phone_eyes.dart';
import '../gallery/widget_gallery.dart';
import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../settings/feature_flags.dart';
import '../social/social_store.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';
import 'together_screen.dart' show askText;
import 'vlm_debug_screen.dart';

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
            title: const Text('Back camera + FPGA'),
            subtitle: Text(_backText(link)),
          ),
          ListTile(
            leading: const Icon(Symbols.photo_camera_front_rounded),
            title: const Text('Front camera'),
            subtitle: Text(link.frontCam?.video.toString() ?? 'Not found'),
          ),
          const _EyeCameraTile(),
          const _CameraRelayTile(),
          const BackendSettingsTile(),
          const _VoiceTile(),
          ListTile(
            leading: const Icon(Symbols.motion_sensor_active_rounded),
            title: const Text('Rear and reflex cameras (mock)'),
            subtitle: Text('${link.streamUrl ?? 'Not found'} · ${link.camBStreamUrl ?? 'not found'}'),
          ),
          ListTile(
            leading: const Icon(Symbols.wifi_tethering_rounded),
            title: const Text('How pairing works'),
            subtitle: Text(
              "Turn on your phone's hotspot. The camera boards join it and say hello on UDP "
              '$camHelloPort; the back camera talks on UDP $backCamPort (and mock_glasses.py on '
              '$appUdpPort). No venue Wi-Fi needed.',
            ),
          ),
          const _TogetherSettings(),
          const _FeatureSwitches(),
          _Header('Privacy'),
          const ListTile(
            leading: Icon(Symbols.videocam_off_rounded),
            title: Text('Camera and voice processing'),
            subtitle: Text('Rear alerts, eye tracking and near-work run on this phone. Voice questions use your device’s speech service. Richer descriptions use Muse when configured.'),
          ),
          const ListTile(
            leading: Icon(Symbols.lock_rounded),
            title: Text('Friends see your rings and stars only'),
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
            const DevOutsideTile(),
          ],
        ],
      ),
    );
  }
}

String _backText(GlassesLink link) {
  final back = link.backCam;
  if (back == null) return 'Not found';
  final s = link.backStatus;
  if (s == null) return '$back · no FPGA report (it has to send them to this phone)';
  final what = s.collision ? 'collision' : s.turning ? 'head turning' : s.tracking ? 'tracking' : 'clear';
  return '$back · ${s.fpga ? 'FPGA $what' : 'FPGA not answering'}${s.imu ? '' : ' · no gyro'}';
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

/// One switch per newer feature, so any can be turned off for a demo.
class _FeatureSwitches extends StatelessWidget {
  const _FeatureSwitches();

  @override
  Widget build(BuildContext context) {
    final flags = context.watch<FeatureFlags>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header('Features'),
        for (final f in Feature.values)
          SwitchListTile.adaptive(
            title: Text(f.title),
            subtitle: Text(f.blurb),
            value: flags[f],
            onChanged: (on) => flags.set(f, on),
          ),
        ListTile(
          leading: const Icon(Symbols.speed_rounded),
          title: const Text('Muse speed check'),
          subtitle: const Text('Time real requests to see how fast descriptions are.'),
          trailing: const Icon(Symbols.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VlmDebugScreen())),
        ),
      ],
    );
  }
}

/// Your Together name, which server it uses, and deleting your data there.
class _TogetherSettings extends StatelessWidget {
  const _TogetherSettings();

  @override
  Widget build(BuildContext context) {
    final social = context.watch<SocialStore>();
    final me = social.me;

    Future<void> run(Future<String?> Function() action, String done) async {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text(await action() ?? done)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header('Together'),
        if (me != null)
          ListTile(
            leading: const Icon(Symbols.badge_rounded),
            title: const Text('Your name'),
            subtitle: Text(me.name),
            onTap: () async {
              final name = await askText(context, title: 'Your name', label: 'Name friends see', action: 'Save');
              if (name != null && name.isNotEmpty) await run(() => social.rename(name), 'Name saved.');
            },
          ),
        ListTile(
          leading: const Icon(Symbols.dns_rounded),
          title: const Text('Together server'),
          subtitle: Text(social.serverUrl.toString()),
          onTap: () async {
            final url = await askText(context, title: 'Together server', label: 'Address', action: 'Use', code: true);
            final uri = url == null ? null : Uri.tryParse(url.toLowerCase());
            if (uri != null && uri.hasScheme) await social.setServer(uri);
          },
        ),
        if (me != null)
          ListTile(
            leading: const Icon(Symbols.delete_rounded),
            title: const Text('Delete my Together data'),
            subtitle: const Text('Removes your name, rings, friends and teams from the server.'),
            onTap: () async {
              final sure = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete your Together data?'),
                  content: const Text('Friends and teams lose you. This can\'t be undone.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (sure == true) await run(social.deleteAccount, 'Your Together data is deleted.');
            },
          ),
      ],
    );
  }
}

/// The eye camera, where its tracking runs, and gaze calibration.
class _EyeCameraTile extends StatelessWidget {
  const _EyeCameraTile();

  @override
  Widget build(BuildContext context) {
    final board = context.watch<GlassesLink>().eyeCam;
    PhoneEyes? eyes;
    try {
      eyes = context.watch<PhoneEyes>();
    } on ProviderNotFoundException {
      eyes = null;
    }
    final onPhone = watchBackend(context)?.onPhone ?? true;
    final step = eyes?.gaze.calibrationStep;
    final String detail;
    if (board == null) {
      detail = 'Not found';
    } else if (!onPhone) {
      detail = '${board.video} · eye tracking runs on the laptop';
    } else if (step != null) {
      detail = '${gazePrompt(step)}…';
    } else {
      detail = '${board.video} · tracked on this phone · gaze ${eyes?.gaze.calibrated == true ? 'calibrated' : 'not calibrated'}';
    }
    return ListTile(
      leading: const Icon(Symbols.visibility_rounded),
      title: const Text('Eye camera'),
      subtitle: Text(detail),
      trailing: board != null && onPhone && eyes != null && step == null
          ? TextButton(onPressed: eyes.calibrateGaze, child: const Text('Calibrate gaze'))
          : null,
    );
  }
}

/// Eye and front cameras on another Wi-Fi, through a relay (tools/cam_relay.py).
class _CameraRelayTile extends StatelessWidget {
  const _CameraRelayTile();

  @override
  Widget build(BuildContext context) {
    final link = context.watch<GlassesLink>();
    final relay = link.relay;
    return ListTile(
      leading: const Icon(Symbols.cloud_sync_rounded),
      title: const Text('Cameras on another network'),
      subtitle: Text(relay == null ? 'Off' : '${relay.authority}${relay.path}'),
      trailing: const Icon(Symbols.edit_rounded),
      onTap: () => _edit(context, link),
    );
  }

  Future<void> _edit(BuildContext context, GlassesLink link) async {
    final controller = TextEditingController(text: link.relay?.toString() ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera relay'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'When the eye and front cameras are on another Wi-Fi, a laptop there runs tools/cam_relay.py '
              'and this phone gets their video from the address it prints. Frames pass through it, newest '
              'only, and are not kept. Cameras on the hotspot are used first. Leave empty to turn it off.',
            ),
            SizedBox(height: context.space.m),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Address', hintText: 'https://omni-glasses.fly.dev/relay/KEY'),
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
    final ok = await link.saveRelay(result);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That doesn\'t look like a relay address (…/relay/KEY).')),
      );
    }
  }
}

/// Which voice speaks, and how to get a more natural one.
class _VoiceTile extends StatelessWidget {
  const _VoiceTile();

  @override
  Widget build(BuildContext context) {
    Voice? voice;
    try {
      voice = context.read<Voice?>();
    } on ProviderNotFoundException {
      voice = null;
    }
    if (voice is! TtsVoice) return const SizedBox.shrink();
    return FutureBuilder<TtsVoiceInfo?>(
      future: voice.chosenVoice(),
      builder: (context, snap) {
        final v = snap.data;
        final text = snap.connectionState != ConnectionState.done
            ? 'Checking…'
            : v == null
            ? 'System default. $betterVoiceHint'
            : v.natural
            ? '$v'
            : '$v (basic). $betterVoiceHint';
        return ListTile(
          leading: const Icon(Symbols.record_voice_over_rounded),
          title: const Text('Voice'),
          subtitle: Text(text),
        );
      },
    );
  }
}
