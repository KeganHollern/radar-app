# Anvil mobile

Flutter iOS/Android client for the live-only Anvil service. It uses
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
`MAP_STYLE_URL`, it must also provide matching map credits so the persistent map
attribution and its source sheet stay accurate:

```sh
--dart-define=MAP_ATTRIBUTION_COMPACT='short persistent credit' \
--dart-define=MAP_PROVIDER_ATTRIBUTION='tile provider' \
--dart-define=MAP_PROVIDER_ATTRIBUTION_URL='https://provider.example/' \
--dart-define=MAP_SCHEMA_ATTRIBUTION='schema credit or empty' \
--dart-define=MAP_SCHEMA_ATTRIBUTION_URL='https://schema.example/' \
--dart-define=MAP_DATA_ATTRIBUTION='map data credit' \
--dart-define=MAP_DATA_ATTRIBUTION_URL='https://data.example/license'
```

Before a mobile release, verify on physical Android and iOS devices in portrait,
landscape, and the smallest supported screen that the persistent credit stays
visible and opens above the native map. Confirm each provider link launches and
TalkBack/VoiceOver exposes one attribution target that announces “map and
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
- The wakelock is enabled while the app is in the foreground and released when
  it is backgrounded.
- Radar metadata uses server-sent events for prompt updates, with 15-second
  metadata polling as a fallback. Only the newest scan is addressable; the app
  contains no timeline or forecast UI.

## Checks

```sh
flutter analyze
flutter test
```

## Android release signing

Release builds never fall back to the Android debug certificate. To produce a
signed APK or app bundle, copy the example and point it at the upload keystore:

```sh
cp android/key.properties.example android/key.properties
flutter build appbundle --release
```

Fill in all four values in `android/key.properties`. That file and all
`*.jks`/`*.keystore` files are ignored by Git; inject them from repository
secrets in CI rather than committing credentials. Without `key.properties`,
release output is intentionally unsigned while debug builds remain unchanged.
