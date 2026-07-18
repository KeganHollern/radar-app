# Radar API

The Go service is a bounded, latest-only proxy for authoritative NOAA/NWS data.
It deliberately has no forecast, animation, history, or arbitrary upstream proxy
endpoint.

## Run

```sh
export RADAR_AGGREGATE_TOKEN_KEY="local-development-key-change-me-32chars"
go run ./cmd/radar-api
```

The server listens on `:8080` by default. Its public production origin defaults
to `https://radar.lystic.dev`.

## Client API

- `GET /` — self-contained HyprRadar marketing page (no upstream dependency)
- `GET /healthz` — process liveness
- `GET /readyz` — process readiness (NOAA outages do not trigger restart loops)
- `GET /api/v1/config` — product, refresh, elevation, color, and URL manifest
- `GET /api/v1/stations` — normalized WSR-88D station GeoJSON
- `GET /api/v1/alerts[?point=lat,lon|area=TX|region=AL]` — active NWS alert GeoJSON
- `GET /api/v1/radar/latest?product=aggregate` — current observation manifest
- `GET /api/v1/radar/latest?product=aggregate&station=KEWX` — the same regional mosaic with one viewport-pinned high-detail radar
- `GET /api/v1/radar/latest?product=reflectivity&station=KFWS&elevation=0.5`
- `GET /api/v1/radar/tiles/{product}/{station}/{elevation}/{z}/{x}/{y}.png?timestamp={version}[&snapshot={signed-aggregate}]`
- `GET /api/v1/updates` — SSE refresh events; accepts the same selection query as `latest`

For the seamless regional-only aggregate use `aggregate/conus/0.5`. A supported
four-character WSR-88D station can replace `conus` to add high-resolution detail
from that one radar without changing sources at tile boundaries. Aggregate tiles
combine current CONUS, Alaska, Hawaii, Caribbean/Puerto Rico, and Guam RIDGE II
layers. The aggregate manifest includes per-region timestamps, uses the oldest
available component for its overall age, and derives its generation from every
regional timestamp plus the optional detail station and scan.

The aggregate `timestamp` is required. Its tile template also carries a compact,
HMAC-signed `snapshot`. Schema 1 contains the five ordered regional observation
times and missing-region mask. Schema 2 additionally contains the chosen detail
station, its exact scan, and canonical site coordinates. Any replica sharing
`RADAR_AGGREGATE_TOKEN_KEY` can reconstruct the exact generation without relying
on pod-local history or doing a metadata request per tile. The existing
24-character timestamp remains in the URL and is cryptographically bound to the
snapshot for rolling-deployment and old-client compatibility. Malformed,
tampered, future, and station/path-mismatched snapshots are rejected before
upstream work. An expired snapshot remains valid only when an exact current or
recently remembered component set confirms a prolonged unchanged generation;
otherwise it is rejected after rollover.

Each regional WMS request is pinned to the exact observation encoded by that
generation. Zoom 7 and above selects the tile's local US radar region; national
zooms 0-6 fetch and composite all available regions at their individual
observation times. Unknown generations are rejected instead of serving current
data under an old URL.

At zoom 9 and above, an aggregate request with an explicit station overlays that
station's 0.5-degree super-resolution reflectivity scan across its coverage.
The client chooses one station for the whole viewport, so neighboring tiles do
not switch radar or scan at an arbitrary grid edge. The station scan is resolved
once per manifest at or immediately before the same regional observation. Both
the regional mosaic and station overlay remove weak signals below approximately
15 dBZ, so a fallback or mode switch does not reveal a second field of weak blue
echoes. Scans more than 10 minutes behind are not used. Tiles use the normal
bounded upstream timeout and fall back to the exact, identically filtered
regional mosaic on timeout, malformed data, or station outage. Requests using
`conus` never perform station metadata or tile work.

For station reflectivity and velocity, `timestamp` is the observation generation
returned by `latest` and is required. The backend verifies that the scan is in
NOAA's current WMS capabilities, rejects future/unlisted scans, and forwards the
exact observation as the WMS `TIME`. A listed generation remains valid for up to
15 minutes after a newer scan appears so a map already on screen can finish
loading every zoom tile from one immutable scan. This short handoff is not a
history API and no timeline is exposed. If a requested scan is newer than one
replica's short metadata cache, that replica performs one bounded capabilities
recheck before applying the same strict validation. Older unlisted timestamps
are rejected directly rather than amplified into upstream requests. Aggregate
generations remain opaque because they encode several distinct regional
observation times.

Station and alert endpoints return GeoJSON. Each alert keeps the complete NWS
properties and gains `radarCategory` and `radarColor`. For an alert without
inline geometry, the API resolves trusted NWS `affectedZones`, combines the
available Polygon/MultiPolygon shapes, and marks the result with
`radarGeometrySource: affectedZones`. Individual zone failures leave partial or
null geometry rather than failing the active-alert response. The properties
`radarGeometryZonesRequested`, `radarGeometryZonesResolved`, and
`radarGeometryPartial` describe fallback completeness even when geometry remains
null. The fetch limit applies only to uncached zones, so successive refreshes can
hydrate alert sets larger than one request budget. Zone-derived rings are
Douglas-Peucker simplified at a bounded `0.0075` degree tolerance to keep mobile
map payloads responsive; ring closure, minimum vertices, holes, and coordinate
bounds are preserved. The response marks these shapes with
`radarGeometrySimplified` and `radarGeometrySimplifyToleranceDegrees`. Inline NWS
alert polygons are not simplified.

Alert normalization is coalesced into one bounded cache slot per query scope.
The raw NWS collection hash is the slot's source revision, so a changed active
set rebuilds immediately while identical concurrent requests share the same
zone-enrichment pass. An unchanged collection is rebuilt after the alert TTL so
additional bounded zone batches can still resolve. If a new collection cannot
be normalized, the last valid collection is served explicitly as stale with its
original fetch/check provenance; malformed data never replaces the last-good
body. Conditional requests accept both strong and weak ETags, including the
weak form produced when an edge proxy compresses the response.

## Important configuration

| Environment variable | Default |
| --- | --- |
| `RADAR_LISTEN_ADDR` | `:8080` |
| `RADAR_PUBLIC_BASE_URL` | `https://radar.lystic.dev` |
| `RADAR_USER_AGENT` | contact-bearing Radar user agent |
| `RADAR_AGGREGATE_TOKEN_KEY` | required shared secret, at least 32 characters |
| `RADAR_ALLOWED_ORIGINS` | `*` |
| `RADAR_UPSTREAM_TIMEOUT` | `8s` |
| `RADAR_ALERT_TTL` | `30s` |
| `RADAR_ALERT_ZONE_TTL` | `24h` |
| `RADAR_ALERT_ZONE_TIMEOUT` | `3s` total resolution budget |
| `RADAR_ALERT_ZONE_FAILURE_TTL` | `1m` negative retry cooldown |
| `RADAR_ALERT_ZONE_MAX_FETCHES` | `64` |
| `RADAR_ALERT_ZONE_CONCURRENCY` | `8` |
| `RADAR_STATION_TTL` | `24h` |
| `RADAR_TILE_TTL` | `20s` |
| `RADAR_METADATA_TTL` | `15s` |
| `RADAR_STALE_AFTER` | `15m` |
| `RADAR_UPDATE_POLL` | `15s` |
| `RADAR_CACHE_MAX_ENTRIES` | `2048` |
| `RADAR_CACHE_MAX_MIB` | `128` |
| `RADAR_MAX_UPSTREAM_MIB` | `16` |
| `RADAR_TILE_MAX_ZOOM` | `16` |

Provider roots are overrideable for testing with `RADAR_NWS_BASE_URL`,
`RADAR_WMS_BASE_URL`, and `RADAR_STATIONS_URL`.

For Kubernetes, create the signing key before starting the new API image:

```sh
kubectl create secret generic radar-api-generation \
  --from-literal=aggregate-token-key="$(openssl rand -base64 48)"
```

Keep this Secret stable across every replica and deployment. For the first
rollout, create the Secret and apply the Deployment's `secretKeyRef` while the
old image is still running, wait for all old-image pods to become ready, and
only then publish/deploy the new image. The old binary safely ignores the extra
environment variable and `snapshot` query parameter; publishing the new image
before the Secret exists makes the intentionally fail-closed process reject its
configuration and restart.

`RADAR_REFLECTIVITY_LAYERS` and `RADAR_VELOCITY_LAYERS` are comma-separated
`elevation:WMS_suffix` mappings. Defaults are `0.5:sr_bref` and `0.5:sr_bvel`.
Only configure a higher tilt when the provider exposes a genuinely distinct WMS
layer. NOAA's current public station WMS does not expose an elevation dimension,
so the default API honestly advertises only 0.5 degrees.
