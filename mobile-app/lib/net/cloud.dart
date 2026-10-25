// The cloud server (cloud/app.py): Together, Call a helper, captions and Muse at
// one HTTPS address, so they work on any network with no laptop. Build with
// `--dart-define=CLOUD_URL=https://omni-glasses.fly.dev`. SOCIAL_URL, HELPER_URL
// and CAPTIONS_URL still override it one service at a time.
//
// Without it, each service uses its laptop default. The glasses' camera
// features always use the laptop backend.

const cloudUrl = String.fromEnvironment('CLOUD_URL');

/// The cloud server's address, or null when the app wasn't built with one.
Uri? get cloudServer => cloudUrl == '' ? null : Uri.parse(cloudUrl);
