# safebrowser-ios

Thin [Capacitor](https://capacitorjs.com/) iOS shell for the **SafeBrowser** parent console.

The app is a WKWebView that loads the remote parent dashboard and registers for
APNs push so a parent is alerted when a child submits an access request. It
contains no application logic of its own — everything is served from the
dashboard at runtime.

## How it works

- `capacitor.config.ts` points `server.url` at the deployed dashboard; the
  WebView loads it directly.
- `@capacitor/push-notifications` registers the device's APNs token (the
  dashboard's bundled bridge code POSTs it to the server) and deep-links a
  tapped notification to the pending-request screen.
- Push entitlement: `aps-environment = production` (TestFlight uses production APNs).

## Build & release

Building, signing, and TestFlight upload run entirely in CI on a GitHub Actions
macOS runner — no local Mac required. Signing uses [fastlane match](https://docs.fastlane.tools/actions/match/)
(certs stored in a separate private repo) with an App Store Connect API key.

- Tag `v*` (e.g. `v0.1.0`) → builds and uploads to TestFlight.
- `init_signing` lane (run once via workflow dispatch) creates and stores the
  signing cert/profile.

No secrets live in this repo — signing material is in CI secrets and the private
match repo; the APNs key lives on the server.
