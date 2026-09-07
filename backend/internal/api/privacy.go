package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
)

var privacyPageETag = func() string {
	digest := sha256.Sum256([]byte(privacyPage))
	return `"` + hex.EncodeToString(digest[:8]) + `"`
}()

func (s *Server) privacy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'")
	w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
	w.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
	w.Header().Set("Permissions-Policy", "accelerometer=(), camera=(), geolocation=(), gyroscope=(), microphone=()")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("ETag", privacyPageETag)
	w.Header().Set("Content-Length", strconv.Itoa(len(privacyPage)))

	if r.Header.Get("If-None-Match") == privacyPageETag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	_, _ = w.Write([]byte(privacyPage))
}

const privacyPage = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="HyprRadar privacy policy">
  <meta name="theme-color" content="#100f0f">
  <title>HyprRadar Privacy Policy</title>
  <style>
    :root { color-scheme: dark; --bg:#100f0f; --panel:#1c1b1a; --line:#403e3c; --text:#cecdc3; --muted:#878580; --paper:#fffcf0; --cyan:#3aa99f; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:16px/1.65 system-ui,-apple-system,"Segoe UI",sans-serif; }
    main, header, footer { width:min(760px,calc(100% - 36px)); margin-inline:auto; }
    header { padding:34px 0 18px; border-bottom:1px solid var(--line); }
    main { padding:24px 0 44px; }
    footer { padding:22px 0 34px; border-top:1px solid var(--line); color:var(--muted); }
    h1,h2 { color:var(--paper); line-height:1.2; }
    h1 { margin:8px 0; font-size:clamp(2rem,8vw,3.2rem); }
    h2 { margin-top:30px; font-size:1.25rem; }
    p,li { max-width:72ch; }
    a { color:var(--cyan); }
    .eyebrow,.updated { color:var(--muted); }
    .summary { padding:16px 18px; background:var(--panel); border:1px solid var(--line); border-radius:14px; }
  </style>
</head>
<body>
  <header>
    <a href="/">← HyprRadar</a>
    <h1>Privacy Policy</h1>
    <p class="updated">Effective and last updated August 21, 2026</p>
  </header>
  <main>
    <p class="summary"><strong>Summary:</strong> HyprRadar has no accounts, ads, or analytics. Location is optional. It is used for the map and, only if you enable it, Near me alerts while the app is closed. HyprRadar does not sell personal data or build a location history.</p>

    <h2>Who operates HyprRadar</h2>
    <p>HyprRadar is maintained by Kegan Hollern (“HyprRadar,” “we,” or “us”). Privacy questions can be sent to <a href="mailto:keganhollern@gmail.com">keganhollern@gmail.com</a>.</p>

    <h2>Data the app accesses and why</h2>
    <ul>
      <li><strong>Foreground location.</strong> If you grant location permission, the app accesses approximate or precise device location to show your position, center or follow the map, choose nearby radar, and reopen at a useful area. Live foreground coordinates are processed on the device.</li>
      <li><strong>Saved startup location.</strong> The app saves latitude, longitude rounded to three decimal places (roughly 100-meter precision), and the observation time in app preferences on your device. It uses this only to choose the next startup view. It overwrites the value as newer accepted locations arrive, and deletes it when next read after it is more than 30 days old. Android backup rules exclude these preferences from cloud backup and device-to-device transfer.</li>
      <li><strong>Optional background location.</strong> If you enable Near me background alerts and choose Android’s “Allow all the time” access, Android may give the app a current or recent location during a periodic check while the app is closed or not in use. Before transmission, HyprRadar rounds latitude and longitude to three decimal places. It sends that point in an encrypted HTTPS POST request body, rather than a URL, through <code>radar.lystic.dev</code> to the U.S. National Weather Service only to request active alerts covering the point. Choosing Nationwide alerts does not use background location.</li>
      <li><strong>Map area and network data.</strong> Loading the visible map and weather layers sends map tile coordinates, requested bounds, IP address, and ordinary network metadata to the services that deliver those layers. A map view can indicate an area you chose to view, which may be near your location.</li>
      <li><strong>App settings.</strong> Alert choices, map-layer choices, notification deduplication identifiers, and similar preferences are stored locally so the app behaves as requested.</li>
    </ul>

    <h2>Services and sharing</h2>
    <p>HyprRadar uses the following parties only to provide app functions:</p>
    <ul>
      <li><a href="https://radar.lystic.dev/">the HyprRadar radar service</a> and Cloudflare deliver weather requests and responses;</li>
      <li><a href="https://www.weather.gov/">the National Weather Service</a> provides radar and alert data and receives the rounded point used for a Near me alert request;</li>
      <li><a href="https://openfreemap.org/">OpenFreeMap</a>, OpenMapTiles, and OpenStreetMap provide the basemap; and</li>
      <li>Android and Google Play services provide operating-system location, background-work, notification, app-distribution, and security functions according to your device and account settings.</li>
    </ul>
    <p>We do not sell personal data. We do not use it for advertising, profiling, or analytics. HyprRadar has no user account system and does not receive your name, email address, contacts, advertising ID, payment data, or health records.</p>

    <h2>Retention and deletion</h2>
    <p>The HyprRadar server does not create user profiles or a persistent location database. A rounded Near me request and its alert response remain only in bounded server-memory caches. Expired entries are actively purged, normally no later than about 12 minutes after the last matching request. The current app keeps the point out of the URL, raw ingress access logging is disabled, and the application log records only the path—not query strings or client IP addresses. Infrastructure providers may process limited network and security data under their own policies.</p>
    <p>You can stop background collection by selecting Nationwide, turning off all background notifications, changing location permission, or clearing/uninstalling the app. Clearing app storage or uninstalling removes HyprRadar’s local settings and saved startup location. Because there is no account or long-term user record on the server, there is no account data to delete. Contact us at the address above with a privacy or deletion question.</p>

    <h2>Security</h2>
    <p>Production app traffic uses HTTPS. Location precision is reduced before a Near me request leaves the device. Server caches are memory-only and bounded, and the app excludes saved location preferences from Android backup. No method of transmission or storage is guaranteed to be completely secure.</p>

    <h2>Children</h2>
    <p>HyprRadar is a general-audience weather tool and is not directed to children under 13. We do not knowingly collect account information from children.</p>

    <h2>Changes</h2>
    <p>We may update this policy when the app or its providers change. The date above will change, and the current policy will remain available at this URL.</p>
  </main>
  <footer><a href="/">HyprRadar home</a> · <a href="https://github.com/KeganHollern/radar-app">source code</a></footer>
</body>
</html>`
