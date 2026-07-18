# HyprRadar

HyprRadar is a live-only U.S. weather radar app designed for a glanceable
driving view. The Flutter client renders a dark MapLibre map, the device
location, active weather alerts, and either a multi-radar mosaic or a selected
WSR-88D station. The Go API owns NOAA/NWS access, validation, normalization, and
caching.

There are deliberately no forecasts, animation loops, or historical timeline.

## Download for Android

Each published [GitHub Release](https://github.com/KeganHollern/radar-app/releases)
includes a signed universal HyprRadar APK and its SHA-256 checksum. Download the
APK on an Android device and allow installation from that source when prompted.

## Repository layout

- `mobile/` — Flutter app for iOS and Android
- `backend/` — Go API and upstream adapters
- `deploy/radar-api.yaml` — Kubernetes resources for `radar.lystic.dev`
- `docs/architecture.md` — data-source decisions, freshness model, safety notes,
  and the Level-II elevation roadmap
- `.github/workflows/api-image.yml` — Go tests and GHCR image publishing
- `.github/workflows/mobile.yml` — Flutter analysis and tests
- `.github/workflows/android-release.yml` — signed APK release publishing

## What works

- dark, pannable/zoomable MapLibre map with roads and place labels
- device location dot, immediate regional startup at the last recent app or
  operating-system fix, one-time live-location correction, and opt-in follow
  mode that keeps the current zoom
- current MRMS/RIDGE aggregate reflectivity, enriched when zoomed in with one
  exact super-resolution station scan pinned to the viewport, with one shared
  weak-signal presentation floor across aggregate and station reflectivity
- tap-to-select WSR-88D stations with current reflectivity and radial velocity
- active NWS alert polygons, persisted per-type visibility settings, overlap
  selection, event colors, and tap-through alert details
- foreground radar and alert refresh, plus coalesced manual retry with visible
  progress and last-check freshness feedback
- foreground wake lock so the screen remains on while HyprRadar is open
- bounded/coalesced upstream caching, stale-on-error behavior, and SSE refresh
- non-root container, health probes, GHCR publishing, and Kubernetes manifests
- responsive Flexoki landing page at `radar.lystic.dev` with no external asset
  dependencies

The current official RIDGE station service exposes only the `0.5°` scan. The UI
and API model support per-product elevation lists, but real higher tilts require
the Level-II ingest/decoder/tile pipeline described in
[`docs/architecture.md`](docs/architecture.md). The app never presents one image
under several fake elevation labels.

## Run the API

Go 1.25 or newer is required.

```bash
cd backend
go test ./...
export RADAR_AGGREGATE_TOKEN_KEY="local-development-key-change-me-32chars"
go run ./cmd/radar-api
```

The API listens on `:8080` by default. For local mobile development, use a
reachable host name or emulator loopback and set `RADAR_PUBLIC_BASE_URL` to the
same origin so generated tile templates remain reachable.

Useful endpoints:

- `GET /` — HyprRadar landing page
- `GET /healthz` and `GET /readyz`
- `GET /api/v1/config`
- `GET /api/v1/stations`
- `GET /api/v1/alerts`
- `GET /api/v1/radar/latest?product=aggregate`
- `GET /api/v1/radar/latest?product=aggregate&station=KEWX`
- `GET /api/v1/radar/latest?product=velocity&station=KDMX&elevation=0.5`
- `GET /api/v1/updates` (server-sent events)

All server configuration uses the `RADAR_` environment variables documented in
`backend/internal/config/config.go`. Non-secret values are mirrored by the
Kubernetes ConfigMap; `RADAR_AGGREGATE_TOKEN_KEY` comes from the
`radar-api-generation` Secret.

## Run the mobile app

```bash
cd mobile
flutter pub get
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8080 \
  --dart-define=MAP_STYLE_URL=https://tiles.openfreemap.org/styles/dark
```

`10.0.2.2` is the Android emulator's host loopback. Use your Mac's LAN address
for a physical device, or omit `API_BASE_URL` to use
`https://radar.lystic.dev`. Location behavior and the native MapLibre renderer
should be validated on physical iOS and Android devices before release.

The default OpenFreeMap style is convenient for development. Choose a production
basemap provider or self-hosted style whose mobile and traffic terms fit the
release before distributing the app.

## Build and deployment

```bash
docker build -t radar-api .
docker run --rm -p 8080:8080 \
  -e RADAR_AGGREGATE_TOKEN_KEY=local-development-key-change-me-32chars \
  radar-api
```

Pushes to `main` publish `ghcr.io/<owner>/<repository>:latest` and a commit tag.
Version tags also publish semantic-version tags. CI never deploys to Kubernetes.

The checked-in deployment follows the existing Lystic cluster conventions, but
it is intentionally unapplied. Review it and use a server-side dry run before
requesting an actual deployment:

```bash
kubectl apply --server-side --dry-run=server -f deploy/radar-api.yaml
```

Do not treat this display as a replacement for Wireless Emergency Alerts, NOAA
Weather Radio, local authorities, or safe driving judgment. Radar reflectivity
is not an exact measurement of rain at road level, and radial velocity is motion
toward or away from a radar rather than absolute surface wind.
