# Radar API

The Go service is a bounded, latest-only proxy for authoritative NOAA/NWS data.
It deliberately has no forecast, animation, history, or arbitrary upstream proxy
endpoint.

## Run

```sh
go run ./cmd/radar-api
```

The server listens on `:8080` by default. Its public production origin defaults
to `https://radar.lystic.dev`.

## Client API

- `GET /healthz` — process liveness
- `GET /readyz` — process readiness (NOAA outages do not trigger restart loops)
- `GET /api/v1/config` — product, refresh, elevation, color, and URL manifest
- `GET /api/v1/stations` — normalized WSR-88D station GeoJSON
- `GET /api/v1/alerts[?point=lat,lon|area=TX|region=AL]` — active NWS alert GeoJSON
- `GET /api/v1/radar/latest?product=aggregate` — current observation manifest
- `GET /api/v1/radar/latest?product=reflectivity&station=KFWS&elevation=0.5`
- `GET /api/v1/radar/tiles/{product}/{station}/{elevation}/{z}/{x}/{y}.png?timestamp={version}`
- `GET /api/v1/updates` — SSE refresh events; accepts the same selection query as `latest`

For aggregate tiles use `aggregate/conus/0.5`; the service normalizes the station
and elevation placeholders. Aggregate tiles combine current CONUS, Alaska,
Hawaii, Caribbean/Puerto Rico, and Guam RIDGE II layers. The aggregate manifest
includes per-region timestamps, uses the oldest available component for its
overall age, and derives its generation from every regional timestamp.

The `timestamp` tile query is a cache-busting generation hint only. The backend
never forwards a requested time to NOAA and always asks WMS for its default
latest image.

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

## Important configuration

| Environment variable | Default |
| --- | --- |
| `RADAR_LISTEN_ADDR` | `:8080` |
| `RADAR_PUBLIC_BASE_URL` | `https://radar.lystic.dev` |
| `RADAR_USER_AGENT` | contact-bearing Radar user agent |
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

`RADAR_REFLECTIVITY_LAYERS` and `RADAR_VELOCITY_LAYERS` are comma-separated
`elevation:WMS_suffix` mappings. Defaults are `0.5:sr_bref` and `0.5:sr_bvel`.
Only configure a higher tilt when the provider exposes a genuinely distinct WMS
layer. NOAA's current public station WMS does not expose an elevation dimension,
so the default API honestly advertises only 0.5 degrees.
