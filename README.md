# safebrowser-ios

Native iOS shell for the **SafeBrowser** parent console, built with Capacitor,
UIKit, and SwiftUI.

The management console remains a remotely loaded WKWebView. Messages use native
SwiftUI screens so keyboard handling, navigation, recording, and message-list
performance follow standard iOS behavior.

## How it works

- `capacitor.config.ts` points `server.url` at the deployed dashboard; the
  WebView loads it directly.
- `NativeShellViewController` keeps the management WebView alive while switching
  between Manage, three configurable management shortcuts, and native Messages.
- The SwiftUI message client reuses the authenticated WKWebView cookie store for
  REST and WebSocket calls. Opening a conversation marks it read; merely viewing
  the conversation list does not.
- `@capacitor/push-notifications` registers the device's APNs token (the
  dashboard's bundled bridge code POSTs it to the server). Request notifications
  deep-link into management; message notifications open the native conversation.
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
