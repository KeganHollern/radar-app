# Anvil architecture

## Product boundary

Anvil is a dark, map-first Flutter application backed by a Go API at
`https://radar.lystic.dev`. It shows only the newest observation available. It
does not expose forecasts, animation, historical scans, or a time selector.

"Live" means *latest observed data received from the upstream provider*, not
zero latency. Every API representation must include its upstream observation
time and the time our service received it. The app must make stale or unavailable
data obvious; it must never silently relabel an old image as current.

The initial API proxies the official NWS RIDGE II OGC services. This provides the
national mosaic and the 0.5-degree reflectivity and velocity scans. True
upper-elevation station views are a separate Level-II ingest/decoder milestone;
the current public RIDGE II WSR-88D layers do not provide them.

## Authoritative data sources

The source choices below were checked on 2026-07-12. Subscribe to NWS service
change notices and revalidate the OGC capabilities regularly rather than treating
layer names as permanent.

### Aggregate reflectivity

Use the NWS CloudGIS/RIDGE II WMS layers for quality-controlled base
reflectivity. The API uses all five regional layers so the same source covers
CONUS, Alaska, Hawaii, Caribbean/Puerto Rico, and Guam:

- service root: `https://opengeo.ncep.noaa.gov/geoserver`
- regional layers: `conus_bref_qcd`, `alaska_bref_qcd`, `hawaii_bref_qcd`,
  `carib_bref_qcd`, and `guam_bref_qcd`
- product: BREF.QCD (quality-controlled 0.5-degree base reflectivity mosaic)

NWS says the composite radar images are produced by Multi-Radar/Multi-Sensor
(MRMS), and documents BREF.QCD as actual dBZ values with clutter/non-precipitation
echoes removed. The same directory exposes the individual station WMS and radar
site WFS. See the [NWS OGC service directory](https://opengeo.ncep.noaa.gov/geoserver/www/index.html)
and [RIDGE II product descriptions](https://www.weather.gov/radarfaq/).

The regional mosaic is approximately a 0.01-degree (roughly 1 km) grid, while
the station `SR_BREF` source is approximately 0.00135 degrees (roughly 150 m).
Requesting a larger mosaic image would only interpolate its existing cells, so
the API uses a real zoom-dependent detail tier instead. At zooms 0-6 it pins and
composites every available regional layer at that aggregate generation's exact
component times. At zoom 7 and above it requests the exact local regional layer.
At zoom 9 and above the client can additionally request one station for the
entire viewport. Its super-resolution reflectivity scan is resolved once at or
immediately before the regional observation and then used across every covered
tile. This avoids the hard seams produced when adjacent tile groups independently
chose different radars and scan times. The station overlay is filtered below
15 dBZ and omitted when it is stale or unavailable. The regional mosaic always
remains the fallback.

This high-zoom overlay is a presentation detail tier, not a different mode or a
history feature. While browsing, the chosen radar follows the camera center;
in Follow mode it follows accepted device locations. A 20 km handoff margin
prevents source thrash near a station boundary, and the previous complete layer
stays visible until its replacement is ready. It remains anchored to the
aggregate generation in the tile URL. The tile template carries a fixed-format,
HMAC-signed snapshot bound to the existing opaque version: schema 1 carries the
five ordered component times and missing mask, while schema 2 also pins the
detail station, exact scan, and canonical coordinates. Any replica with the
shared signing key can therefore reconstruct the exact WMS times without
pod-local history or a per-tile metadata lookup. Brief in-memory history remains
only as a mixed-rollout fallback for older URLs without the snapshot parameter.

The production alternative is to ingest the current MRMS GRIB2 artifact directly,
for example `MRMS_ReflectivityAtLowestAltitude.latest.grib2.gz`, render immutable
tiles, and atomically advance a generation pointer. NOAA publishes operational
MRMS products in real time over HTTP in GRIB2, and MRMS is explicitly a seamless
multi-radar/multi-sensor mosaic. See [NOAA MRMS](https://mrms.nssl.noaa.gov/),
[the current MRMS product tree](https://mrms.ncep.noaa.gov/2D/), and the
[reflectivity-at-lowest-altitude feed](https://mrms.ncep.noaa.gov/2D/ReflectivityAtLowestAltitude/).
Direct ingestion gives stronger freshness and cache control but adds GRIB2
decoding, projection, coloring, tiling, and monitoring work. It is not in the
initial proxy.

"Reflectivity" is not synonymous with rain at the road surface. Beam blockage,
beam height at distance, anomalous propagation, snow/hail, biological targets,
and outages can all affect the display. The UI should say "reflectivity" and
avoid claims of exact rainfall at the driver's position.

### Stations, reflectivity elevations, and velocity

Use the official radar-site WFS as the station catalog:

```text
https://opengeo.ncep.noaa.gov/geoserver/nws/ows
  ?request=GetFeature
  &service=WFS
  &typeName=nws:radar_sites
  &version=1.0.0
  &outputFormat=application/json
```

The RIDGE II directory lists, per WSR-88D site:

- `SR_BREF`: super-resolution base reflectivity, dBZ, 0.5-degree scan
- `SR_BVEL`: super-resolution base radial velocity, knots, 0.5-degree scan

NWS specifically documents both public WSR-88D layers as 0.5-degree data. Do not
manufacture elevation options by assigning the same image to multiple labels.
The app's current manifest therefore advertises only `0.5`.

Station reflectivity is intentionally less visually clean than the aggregate
`BREF.QCD` mosaic. The WSR-88D can detect very weak returns below the level
usually associated with measurable precipitation, and base reflectivity can
also contain returns from insects, birds, dust, ground clutter, and anomalous
propagation. NOAA's station legend renders those weak returns in pale gray and
blue shades. For the app's rain-focused driving view, the API applies a
presentation floor of approximately 15 dBZ to station reflectivity only. The
source is a pre-colored raster, so the filter matches the official NOAA palette
and fails open for unknown colors. This is not meteorological quality control
and can hide boundaries, virga, very light precipitation, and biological
returns. Aggregate reflectivity and station velocity are never filtered.
Actual WMS no-data pixels are transparent and remain transparent through the
tile proxy. Opaque white is also part of NOAA's palette for strong
reflectivity, so the filter classifies the full palette rather than treating
white as background.

To support the requested elevation selector correctly, ingest near-real-time
NEXRAD Level-II volumes. NCEI documents Level II as the original-resolution base
quantities—reflectivity, mean radial velocity, and spectrum width—and explains
that a volume coverage pattern is made from 360-degree sweeps at predetermined
elevations. A volume commonly takes roughly 4.5–10 minutes, depending on scanning
mode, with supplemental low-level rescans possible. See [NCEI's NEXRAD product
documentation](https://www.ncei.noaa.gov/products/radar/next-generation-weather-radar)
and the [Level-II dataset record](https://www.ncei.noaa.gov/access/metadata/landing-page/bin/iso?id=gov.noaa.ncdc:C00345).

The current NODD distribution pattern is:

- Level-II archive/current volumes: `s3://unidata-nexrad-level2`
- real-time Level-II chunks: `s3://unidata-nexrad-level2-chunks`
- filterable new-object notifications:
  `arn:aws:sns:us-east-1:684042711724:NewNEXRADLevel2ObjectFilterable`

The old `noaa-nexrad-level2` bucket was deprecated and scheduled for removal on
2025-09-01; new code must not use it. The registry says new Level-II data is added
as soon as available and NOAA NODD data is public. See [NEXRAD on the AWS Open Data
Registry](https://registry.opendata.aws/noaa-nexrad/). NCEI also identifies NODD
cloud access as historical and near-real-time Level-II/III access.

Level-II implementation sequence:

1. Discover new station objects from notifications where practical, with bucket
   listing/polling as reconciliation and outage recovery.
2. Assemble a complete volume from chunks or consume the completed volume. Reject
   partial/corrupt messages and validate station ID and payload timestamps.
3. Decode the volume using the current WSR-88D Interface Control Documents. Build
   the available elevation list from the actual volume; VCPs and supplemental
   scans mean it cannot be a hard-coded list.
4. Render reflectivity and radial velocity to georeferenced raster tiles. Keep
   the original physical units and apply color tables at a documented stage.
5. Publish all tiles and metadata under an immutable scan generation, then advance
   the station's `latest` pointer atomically. Retain an older generation only for
   in-flight requests; never expose it through a history API.
6. Mark a station stale/unavailable instead of falling back to an unrelated old
   scan. Keep the national mosaic usable when an individual radar is down.

Velocity is motion toward or away from the radar, not a map of absolute surface
wind speed or direction. The API and legend must call it **radial velocity**.
NOAA's station palette uses green for negative velocity (toward the radar), red
for positive velocity (away from the radar), and a separate magenta/purple
range-folded marker where velocity could not be resolved. Range-folded pixels
are data-quality flags, not precipitation or velocity magnitudes, and must not
be folded into the numeric color scale. As with reflectivity, no-data pixels
are transparent.

Station manifests identify one exact NOAA observation. Every reflectivity or
velocity tile request must include that generation; the API validates it against
the layer's advertised WMS time dimension and sends the exact `TIME` upstream.
A previous listed scan is accepted only during a bounded 15-minute handoff so
tiles requested at different zoom levels cannot silently cross a scan rollover.
This is generation consistency for the live display, not historical access.
Because API replicas have independent short metadata caches, a replica performs
one timeout-bounded capabilities refresh when the requested station generation
is newer than its cached default, then validates the fresh response normally.
Older unlisted timestamps are rejected without another upstream request. This
prevents a just-published manifest from producing intermittent blank tiles on
another replica without creating an amplification path or relaxing generation
checks.

Radar rasters still have finite spatial resolution. A low map zoom necessarily
undersamples small velocity features that become visible at higher zoom, even
when both levels use the same scan. Nearest-neighbor client resampling avoids
inventing blended velocity colors but cannot preserve details smaller than a
requested WMS pixel.

### Weather alerts

Use `https://api.weather.gov/alerts/active` and request GeoJSON with a unique,
contact-bearing `User-Agent`. The app needs alert geometry plus the CAP-derived
event, headline, description, instruction, onset/effective/ends/expires,
severity, certainty, urgency, sender, status, and message type. The full text
shown on tap should remain faithful to NWS content.

NWS asks API consumers to poll no more often than every 30 seconds and enforces
rate limiting. Poll once in the backend, use conditional requests when supported,
and fan the normalized result out to all clients; mobile devices must not each
poll NWS. Replace the active set by stable alert ID so updates and cancellations
remove obsolete geometry. See the [NWS Alerts Web Service](https://www.weather.gov/documentation/services-web-alerts)
and [NWS API documentation](https://www.weather.gov/documentation/services-web-api).

Some alerts are polygon-based while many identify forecast/county zones. When an
alert has no inline polygon, resolve and cache its affected-zone geometry rather
than dropping it. NWS explicitly notes that many alerts define their area by NWS
forecast zone. This fallback can be less precise, so preserve that distinction in
metadata.

The API implements that fallback with trusted NWS zone URLs, a bounded concurrent
lookup budget, and a 24-hour geometry cache. Available Polygon/MultiPolygon shapes
are simplified at `0.0075°` before being combined into one MultiPolygon and
marked `radarGeometrySource`; inline NWS warning polygons remain unchanged. The
simplification keeps nationwide alert refreshes responsive on mobile devices.
Individual zone failures leave partial or null geometry without hiding the alert.

Alert visibility is a device-local presentation preference. All event types are
visible by default; the Settings panel persists disabled NWS event names and
uses the same filtered collection for polygons, the active count, the alert
list, and map-tap resolution. Filtering never cancels or changes the underlying
NWS product. When several visible polygons cover one tap point, query every
rendered alert feature there and present a chooser before opening the existing
detail sheet.

The map should fill alert geometry with an explicit, accessible event/severity
color policy and a strong outline. Color is presentation, not an NWS-defined
priority ordering; never infer danger from color alone. Show label/legend text
and the CAP severity, urgency, and certainty. NWS CAP is weather-alert data, not
the complete set of non-weather emergency alerts, and NWS says it must not be used
to activate EAS. The app is a supplemental display, not a replacement for WEA,
NOAA Weather Radio, local authorities, or safe driving judgment.

## Runtime data flow

```text
NWS CloudGIS WMS/WFS ─┐
NWS Alerts API ───────┼──> Go API cache/normalizer ──> HTTPS ──> Flutter/MapLibre
NODD Level II (phase) ┘           │                                  │
                                 └── newest generation metadata      ├─ dark basemap
                                                                        radar raster
                                                                        alert fill
                                                                        location dot
```

The mobile app owns location permission, the location dot, map gestures, and
pin/follow state. Location is not sent to the backend for the basic radar view.
The first live device fix focuses the startup map once at zoom 8, unless the
user has already interacted with the map or enabled follow. This startup focus
does not turn on continuous tracking.
When follow is enabled, each accepted location update recenters the map without
changing zoom or bearing. Only the explicit pin control should disable follow;
if panning remains enabled while pinned, the next accepted location update returns
the user to center. The Flutter wakelock is held only while the radar screen is
visible and is released when the app becomes inactive/backgrounded.

The Go service owns upstream requests, validation, upstream polling limits, cache
policy, normalization, and stable client contracts. It should never expose arbitrary
upstream URLs or accept an unrestricted WMS query string from clients.

### Refresh contract

- Poll alert data centrally no faster than every 30 seconds.
- Poll current WMS metadata on the configured interval; refresh displayed tiles
  only when the upstream observation/generation changes.
- Use the server-sent-event refresh stream for prompt foreground updates, with
  the app-side metadata poll as recovery after disconnect or backgrounding.
- A foreground/resumed app requests metadata immediately.
- Cache keys include product, station, elevation, tile coordinate, and immutable
  upstream generation. `latest` metadata should have a short cache lifetime;
  generation-addressed tiles may be cached much longer.
- Require and validate the aggregate or station generation on every radar tile,
  and pin every upstream WMS `TIME`; never resolve `latest` independently for an
  individual tile.
- Reject malformed or invalid aggregate signatures before any upstream request.
  Keep the signing key in a shared Kubernetes Secret, never in a ConfigMap or
  image, and bind the signature to the product and opaque generation hash.
- Coalesce concurrent cache misses so hundreds of clients do not create hundreds
  of identical upstream WMS requests.
- Surface `observedAt`, `receivedAt`, `ageSeconds`, and `stale` in manifests.
  Readiness should fail only when the process cannot serve its contract, not for a
  short upstream outage; product metadata carries upstream health/staleness.

The current in-memory cache is per pod. Two replicas therefore provide process
availability but may each make one upstream request per cache key. Before large
public usage or Level-II rendering, split ingestion/rendering from the stateless
API and use shared object storage for immutable current-generation tiles. A
single elected ingest worker (with a reconciliation loop) prevents duplicate
national/station processing; API replicas serve the published generations.

## Basemap and visual system

Use a MapLibre-compatible vector style configured at build/runtime. The style and
tile provider are separate from NOAA radar data and must have production terms
that permit mobile use and the expected traffic; do not point a distributed app
at a community/demo tile endpoint. Keep provider URL/token outside source control.

The dark palette follows the referenced `lystic-web` Flexoki theme:

| Role | Flexoki dark |
| --- | --- |
| map/app background | `#100F0F` |
| raised panel | `#1C1B1A` |
| selected/hover surface | `#343331` |
| border | `#403E3C` |
| primary text | `#CECDC3` |
| secondary text | `#878580` |
| cyan/active control | `#3AA99F` |
| warning orange | `#DA702C` |
| destructive red | `#D14D41` |

Road, place, boundary, and water colors belong in the basemap style. Radar and
alert colors must preserve meteorological meaning and accessible contrast rather
than being forced into the decorative palette. Include source attribution required
by the selected basemap provider.

## API and security expectations

- All public traffic terminates as TLS at `radar.lystic.dev`.
- Validate station IDs, product names, elevation values, and slippy-map bounds
  against server-owned allowlists. Cap upstream response size and request time.
- Do not log precise user location. The basic API does not require it.
- Apply per-IP/client rate limits at ingress or API, but allow normal tile bursts
  after a map move.
- Use bounded caches and request coalescing. A tile coordinate attack must not
  create unbounded memory or upstream work.
- Send explicit cache headers, content types, CORS policy, and a request ID.
- Preserve NOAA attribution and never imply NOAA endorsement. If rendered or
  otherwise modified, do not describe the result as original, unaltered NOAA data.

## Kubernetes and release operations

`deploy/radar-api.yaml` mirrors the inspected `tesl` conventions: namespace
`default`, two rolling replicas, non-root execution, `enableServiceLinks: false`,
GHCR `:latest`, Keel polling, ClusterIP Service, and NGINX Ingress. It adds HTTP
health/readiness probes, a disruption budget, a read-only root filesystem, dropped
capabilities, bounded `/tmp`, and resource requests/limits.

The manifest has **not** been applied. Before an operator applies it:

1. Confirm `ghcr.io/keganhollern/radar-app:latest` exists. The manifest references
   the existing `default/ghcr-pull` Secret so it can pull a private package.
2. Confirm DNS for `radar.lystic.dev` targets the ingress.
3. Confirm `default/lystic-wildcard-tls` remains the certificate Secret. A
   read-only cluster lookup confirmed that name on 2026-07-12; the checked-in
   Cloudflare tunnel already routes `*.lystic.dev` to the NGINX ingress.
4. Review requests/limits under realistic tile concurrency. Level-II decoding and
   rendering will need a separately sized worker rather than silently increasing
   API pod work.
5. Verify the NWS `User-Agent` contact and upstream rate/cache configuration.
6. Run a server-side dry run and inspect the diff, then obtain explicit permission
   before any real Kubernetes mutation.

The GitHub workflows test Go and Flutter on pull requests. The API workflow also
builds the image; pushes to the default branch publish `latest` and a commit tag
to GHCR, while version tags publish semantic-version tags. CI deliberately does
not run `kubectl`. Keel may update an already-installed deployment after `latest`
changes, so enabling the deployment is itself an operational decision.

## Known gaps before the full requested product

- Current NWS WMS station mode is lowest tilt only. A Level-II decoder, renderer,
  current-generation store, and ingest worker are required for upper elevations.
- The basemap provider/style URL and production licensing are not selected yet.
- Zone-derived alert geometry and the event-to-style policy still need
  validation across a broad set of real active-alert samples.
- The public tile route needs edge rate limiting before a large public launch.
  The present cloudflared/ingress setup does not trust end-user forwarded IPs, so
  per-source-IP NGINX limits would incorrectly pool all users behind cloudflared
  and are intentionally not enabled in this app manifest.
- End-to-end freshness SLOs, upstream outage alerts, and data-age dashboards need
  production traffic and chosen ingest strategy.
- Background behavior needs on-device tests. The app is live while foregrounded;
  mobile operating systems may suspend background network/location work.
- Driver-distraction behavior needs a product decision: recommended defaults are
  large controls, no required typing, no animated timeline, and minimal interaction
  while motion is detected.
