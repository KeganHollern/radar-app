# HyprRadar mobile

Flutter iOS/Android client for the live-only HyprRadar service. It uses
MapLibre, shows current NEXRAD raster tiles and NWS alert polygons, and can keep
the map centered on the device without changing the user's zoom.

## Run

```sh
flutter pub get
flutter run
```

The production API and the OpenFreeMap dark style are defaults. Override either
at build/run time:

```sh
flutter run \
  --dart-define=API_BASE_URL=http://localhost:8080 \
  --dart-define=MAP_STYLE_URL=https://tiles.openfreemap.org/styles/dark
```

The default map style and credits are the OpenFreeMap dark style:
`OpenFreeMap © OpenMapTiles Data from OpenStreetMap`. If a release changes
`MAP_STYLE_URL`, it must also provide matching map credits so the compact source
button's accessibility label and source sheet stay accurate:

```sh
--dart-define=MAP_ATTRIBUTION_COMPACT='short accessibility credit' \
--dart-define=MAP_PROVIDER_ATTRIBUTION='tile provider' \
--dart-define=MAP_PROVIDER_ATTRIBUTION_URL='https://provider.example/' \
--dart-define=MAP_SCHEMA_ATTRIBUTION='schema credit or empty' \
--dart-define=MAP_SCHEMA_ATTRIBUTION_URL='https://schema.example/' \
--dart-define=MAP_DATA_ATTRIBUTION='map data credit' \
--dart-define=MAP_DATA_ATTRIBUTION_URL='https://data.example/license'
```

Before a mobile release, verify on physical Android and iOS devices in portrait,
landscape, and the smallest supported screen that the compact source button
stays visible and opens above the native map. Confirm each provider link launches
and TalkBack/VoiceOver exposes one attribution target that announces “map and
weather data sources.”

An Android emulator reaches a host API at `http://10.0.2.2:8080`; debug and
profile builds allow cleartext specifically for local development, while the
release manifest remains HTTPS-only. iOS Simulator can normally use
`http://localhost:8080`; local cleartext HTTP may require a development-only
App Transport Security exception. Production should remain HTTPS.

## Device behavior

- Location permission is requested at runtime. The native declarations live in
  `android/app/src/main/AndroidManifest.xml` and `ios/Runner/Info.plist`.
- The first live location fix centers the startup map once at a regional zoom.
  It does not enable follow mode, and a user gesture before the fix keeps camera
  control with the user.
- Test follow mode on a physical device or with a simulated route. It uses the
  native location engine and retains the current map zoom while tracking.
- Portrait keeps the established top status card and bottom map controls.
  Landscape uses compact status and radar-control rails on the left and right,
  leaving the center of the map visible. Radar modes, settings, alerts, alert
  details, and source credits open in full-height side panels in landscape so
  their content remains reachable on short screens.
- Nearby chooses one high-detail radar for the whole viewport. Camera-idle
  updates drive the choice while browsing; accepted device locations own it in
  follow mode. A handoff margin prevents GPS jitter from repeatedly rebuilding
  the radar source. Native raster layers are double-buffered so the previous
  complete image remains visible while a new station or scan loads, and
  MapLibre crossfades generation-pinned parent/child tiles during zoom changes.
  Regional radar remains visible during a detail outage.
  Nearby and station reflectivity share the same approximately 15 dBZ
  presentation floor so weak blue echoes do not reappear when modes change.
- The wakelock is enabled while the app is in the foreground and released when
  it is backgrounded.
- Radar metadata uses server-sent events for prompt updates, with 15-second
  metadata polling as a fallback. Only the newest scan is addressable; the app
  contains no timeline or forecast UI.
- Alert refreshes are single-flight: automatic signals join existing work, and
  a manual retry that arrives during a request queues one follow-up instead of
  disappearing. The stale-data banner shows progress while retrying, retains
  the last valid polygons on failure, and reports the API's latest check time.

## Checks

```sh
flutter analyze
flutter test
```

## Android releases and signing

Release builds never fall back to the Android debug certificate. To produce a
signed APK locally, copy the example and point it at the upload keystore:

```sh
cp android/key.properties.example android/key.properties
flutter build apk --release
```

Fill in all four values in `android/key.properties`. That file and all
`*.jks`/`*.keystore` files are ignored by Git; inject them from repository
secrets in CI rather than committing credentials. Without `key.properties`,
release output is intentionally unsigned while debug builds remain unchanged.

Publishing a GitHub Release automatically builds HyprRadar's signed universal
Android APK and attaches it with a SHA-256 checksum. The release tag must be
`v<version>`, where `<version>` exactly matches the version name before `+` in
`pubspec.yaml` (for example, `version: 1.0.1+11` uses tag `v1.0.1`). A manual run
of the **Android release** workflow performs the same build and validation but
only creates a temporary Actions artifact; it never publishes to a GitHub
Release.

The workflow requires the `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`
repository secrets. Keep a secure backup of the same permanent signing key:
Android will reject future HyprRadar updates signed with a different key.

The permanent release certificate SHA-256 fingerprint is:
`F8:1C:8C:60:14:56:4E:B9:BE:08:66:FE:E6:0C:1F:7F:66:9A:29:A3:43:8A:C8:58:7A:EC:0B:D0:0F:E1:9F:1D`.
