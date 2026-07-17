package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
)

var landingPageETag = func() string {
	digest := sha256.Sum256([]byte(landingPage))
	return `"` + hex.EncodeToString(digest[:8]) + `"`
}()

func (s *Server) landing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'")
	w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
	w.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
	w.Header().Set("Permissions-Policy", "accelerometer=(), camera=(), geolocation=(), gyroscope=(), microphone=()")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("ETag", landingPageETag)
	w.Header().Set("Content-Length", strconv.Itoa(len(landingPage)))

	if r.Header.Get("If-None-Match") == landingPageETag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	_, _ = w.Write([]byte(landingPage))
}

const landingPage = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Anvil is a live-only weather radar built for a clear, glanceable view of the road ahead.">
  <meta name="theme-color" content="#100f0f">
  <title>Anvil — Live weather radar</title>
  <style>
    :root {
      color-scheme: dark;
      --black: #100f0f;
      --base-50: #1c1b1a;
      --base-100: #282726;
      --base-150: #343331;
      --base-200: #403e3c;
      --base-300: #575653;
      --base-500: #878580;
      --base-700: #cecdc3;
      --paper: #fffcf0;
      --red: #d14d41;
      --orange: #da702c;
      --yellow: #d0a215;
      --green: #879a39;
      --cyan: #3aa99f;
      --blue: #4385be;
      --purple: #8b7ec8;
      --shadow: 0 30px 80px rgba(0, 0, 0, .46);
    }

    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      min-width: 320px;
      margin: 0;
      overflow-x: hidden;
      color: var(--base-700);
      background:
        radial-gradient(circle at 78% 18%, rgba(58, 169, 159, .13), transparent 28rem),
        radial-gradient(circle at 7% 65%, rgba(67, 133, 190, .10), transparent 26rem),
        var(--black);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      -webkit-font-smoothing: antialiased;
    }

    a { color: inherit; }
    a:focus-visible {
      outline: 3px solid var(--cyan);
      outline-offset: 4px;
      border-radius: 6px;
    }
    .skip-link {
      position: fixed;
      z-index: 20;
      top: 12px;
      left: 12px;
      padding: 10px 14px;
      color: var(--black);
      background: var(--paper);
      border-radius: 8px;
      transform: translateY(-160%);
    }
    .skip-link:focus { transform: translateY(0); }

    .shell {
      width: min(1120px, calc(100% - 40px));
      margin-inline: auto;
    }
    .site-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      min-height: 84px;
      border-bottom: 1px solid rgba(87, 86, 83, .44);
    }
    .brand {
      display: inline-flex;
      align-items: center;
      gap: 11px;
      color: var(--paper);
      font-size: 1.05rem;
      font-weight: 760;
      letter-spacing: -.02em;
      text-decoration: none;
    }
    .brand-mark {
      display: grid;
      width: 38px;
      height: 38px;
      overflow: hidden;
      place-items: center;
      border: 1px solid var(--base-200);
      border-radius: 11px;
      background: var(--base-50);
      box-shadow: 0 8px 24px rgba(0, 0, 0, .3);
    }
    .brand-mark svg { width: 100%; height: 100%; }
    .site-nav {
      display: flex;
      align-items: center;
      gap: clamp(16px, 3vw, 30px);
      font-size: .9rem;
      font-weight: 650;
    }
    .site-nav a {
      padding-block: 8px;
      text-decoration: none;
    }
    .site-nav a:hover { color: var(--paper); }

    .hero {
      display: grid;
      grid-template-columns: minmax(0, 1.08fr) minmax(280px, .92fr);
      align-items: center;
      gap: clamp(38px, 8vw, 110px);
      min-height: min(760px, calc(100svh - 84px));
      padding-block: 64px 84px;
    }
    .hero-copy { min-width: 0; }
    .eyebrow {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      margin: 0 0 20px;
      color: var(--cyan);
      font-size: .75rem;
      font-weight: 800;
      letter-spacing: .14em;
      text-transform: uppercase;
    }
    .live-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--cyan);
      box-shadow: 0 0 0 5px rgba(58, 169, 159, .13);
    }
    h1 {
      max-width: 690px;
      margin: 0;
      color: var(--paper);
      font-size: clamp(3.25rem, 7vw, 6.6rem);
      font-weight: 780;
      letter-spacing: -.075em;
      line-height: .93;
    }
    h1 span { color: var(--cyan); }
    .lede {
      max-width: 610px;
      margin: 28px 0 0;
      color: var(--base-700);
      font-size: clamp(1.05rem, 2vw, 1.28rem);
      line-height: 1.6;
    }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin-top: 34px;
    }
    .button {
      display: inline-flex;
      min-height: 48px;
      align-items: center;
      justify-content: center;
      gap: 9px;
      padding: 0 18px;
      border: 1px solid var(--base-300);
      border-radius: 12px;
      color: var(--paper);
      background: rgba(28, 27, 26, .72);
      font-size: .92rem;
      font-weight: 720;
      text-decoration: none;
      transition: border-color .18s ease, background .18s ease, transform .18s ease;
    }
    .button.primary {
      border-color: var(--cyan);
      color: var(--black);
      background: var(--cyan);
    }
    .button:hover {
      border-color: var(--base-700);
      transform: translateY(-2px);
    }
    .button.primary:hover { border-color: #57b9b0; background: #57b9b0; }
    .button svg { width: 17px; height: 17px; }
    .live-only {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-top: 28px;
      color: var(--base-500);
      font-size: .82rem;
      line-height: 1.5;
    }
    .live-only svg { flex: 0 0 auto; color: var(--green); }

    .phone-stage {
      position: relative;
      display: grid;
      min-height: 550px;
      place-items: center;
      isolation: isolate;
    }
    .phone-stage::before {
      position: absolute;
      z-index: -1;
      width: 74%;
      aspect-ratio: 1;
      border: 1px solid rgba(58, 169, 159, .20);
      border-radius: 50%;
      background: radial-gradient(circle, rgba(58, 169, 159, .14), rgba(58, 169, 159, 0) 66%);
      content: "";
      box-shadow: 0 0 0 48px rgba(58, 169, 159, .025), 0 0 0 96px rgba(58, 169, 159, .014);
    }
    .phone-figure { margin: 0; text-align: center; }
    .phone {
      position: relative;
      width: min(272px, 72vw);
      aspect-ratio: 9 / 19.4;
      padding: 8px;
      overflow: hidden;
      border: 1px solid #575653;
      border-radius: 44px;
      background: #191817;
      box-shadow: var(--shadow), inset 0 0 0 2px #282726;
      transform: rotate(2.25deg);
    }
    .screen {
      position: relative;
      width: 100%;
      height: 100%;
      overflow: hidden;
      border-radius: 36px;
      background: #1c1b1a;
    }
    .screen-map {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
    }
    .island {
      position: absolute;
      z-index: 7;
      top: 13px;
      left: 50%;
      width: 74px;
      height: 22px;
      border-radius: 999px;
      background: #100f0f;
      transform: translateX(-50%);
    }
    .status-bar {
      position: absolute;
      z-index: 6;
      top: 16px;
      left: 18px;
      right: 18px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      color: var(--paper);
      font-size: 8px;
      font-weight: 750;
    }
    .status-icons { display: flex; align-items: center; gap: 4px; }
    .status-icons i { display: block; width: 9px; height: 5px; border: 1px solid var(--paper); border-radius: 1px; }
    .top-pill {
      position: absolute;
      z-index: 5;
      top: 48px;
      left: 14px;
      display: flex;
      align-items: center;
      gap: 7px;
      padding: 8px 10px;
      border: 1px solid rgba(87, 86, 83, .86);
      border-radius: 11px;
      color: var(--paper);
      background: rgba(28, 27, 26, .90);
      box-shadow: 0 5px 16px rgba(0, 0, 0, .35);
      font-size: 9px;
      font-weight: 780;
    }
    .top-pill b { color: var(--cyan); font-size: 6px; letter-spacing: .08em; }
    .map-control {
      position: absolute;
      z-index: 5;
      right: 14px;
      display: grid;
      width: 35px;
      height: 35px;
      place-items: center;
      border: 1px solid rgba(87, 86, 83, .88);
      border-radius: 11px;
      color: var(--paper);
      background: rgba(28, 27, 26, .91);
      box-shadow: 0 5px 16px rgba(0, 0, 0, .3);
    }
    .map-control.one { top: 48px; }
    .map-control.two { top: 91px; }
    .map-control svg { width: 16px; height: 16px; }
    .location {
      position: absolute;
      z-index: 5;
      top: 54%;
      left: 50%;
      width: 17px;
      height: 17px;
      border: 3px solid var(--paper);
      border-radius: 50%;
      background: var(--blue);
      box-shadow: 0 0 0 7px rgba(67, 133, 190, .20), 0 4px 10px rgba(0, 0, 0, .5);
      transform: translate(-50%, -50%);
    }
    .alert-chip {
      position: absolute;
      z-index: 5;
      bottom: 79px;
      left: 14px;
      display: flex;
      align-items: center;
      gap: 6px;
      max-width: calc(100% - 28px);
      padding: 7px 9px;
      border: 1px solid rgba(209, 77, 65, .7);
      border-radius: 9px;
      color: var(--paper);
      background: rgba(28, 27, 26, .92);
      font-size: 7px;
      font-weight: 710;
    }
    .alert-chip i { width: 7px; height: 7px; border-radius: 2px; background: var(--red); }
    .legend {
      position: absolute;
      z-index: 5;
      right: 14px;
      bottom: 38px;
      left: 14px;
      padding: 7px 8px 6px;
      border: 1px solid rgba(87, 86, 83, .78);
      border-radius: 9px;
      background: rgba(28, 27, 26, .90);
    }
    .legend-labels { display: flex; justify-content: space-between; margin-bottom: 4px; color: var(--base-700); font-size: 6px; }
    .legend-bar {
      height: 5px;
      border-radius: 99px;
      background: linear-gradient(90deg, var(--cyan), var(--blue), var(--green), var(--yellow), var(--orange), var(--red), var(--purple));
    }
    .home-indicator {
      position: absolute;
      z-index: 6;
      bottom: 12px;
      left: 50%;
      width: 82px;
      height: 3px;
      border-radius: 99px;
      background: rgba(255, 252, 240, .8);
      transform: translateX(-50%);
    }
    figcaption {
      max-width: 290px;
      margin: 20px auto 0;
      color: var(--base-500);
      font-size: .78rem;
      line-height: 1.5;
    }

    .features {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      border-top: 1px solid var(--base-200);
      border-bottom: 1px solid var(--base-200);
    }
    .feature { padding: clamp(28px, 5vw, 48px); }
    .feature + .feature { border-left: 1px solid var(--base-200); }
    .feature-number {
      color: var(--cyan);
      font-size: .7rem;
      font-weight: 800;
      letter-spacing: .12em;
    }
    .feature h2 {
      margin: 14px 0 10px;
      color: var(--paper);
      font-size: 1.1rem;
      letter-spacing: -.02em;
    }
    .feature p { margin: 0; font-size: .9rem; line-height: 1.6; }

    .open-source {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 34px;
      padding-block: 82px;
    }
    .open-source h2 {
      margin: 0 0 12px;
      color: var(--paper);
      font-size: clamp(1.8rem, 4vw, 3rem);
      letter-spacing: -.05em;
    }
    .open-source p { max-width: 610px; margin: 0; line-height: 1.65; }
    .site-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      min-height: 96px;
      border-top: 1px solid var(--base-200);
      color: var(--base-500);
      font-size: .78rem;
    }
    .site-footer a { color: var(--base-700); text-underline-offset: 3px; }

    @media (max-width: 820px) {
      .hero { grid-template-columns: 1fr; padding-top: 70px; text-align: center; }
      .hero-copy { display: grid; justify-items: center; }
      .hero-copy > * { max-width: 100%; }
      h1, .lede { width: 100%; }
      .phone-stage { min-height: 570px; }
      .features { grid-template-columns: 1fr; }
      .feature + .feature { border-top: 1px solid var(--base-200); border-left: 0; }
      .open-source { align-items: flex-start; flex-direction: column; }
    }
    @media (max-width: 540px) {
      .shell { width: min(calc(100% - 28px), 1120px); }
      .site-header { min-height: 72px; }
      .site-nav a:first-child { display: none; }
      .hero { min-height: auto; padding-block: 58px 70px; }
      h1 { font-size: clamp(3rem, 16vw, 4.5rem); }
      .lede { font-size: 1rem; }
      .actions { width: 100%; flex-direction: column; }
      .button { width: 100%; }
      .phone-stage { min-height: 520px; }
      .phone { transform: none; }
      .features { margin-inline: -14px; }
      .open-source { padding-block: 64px; }
      .site-footer { align-items: flex-start; flex-direction: column; justify-content: center; padding-block: 26px; }
    }
    @media (max-width: 420px) {
      .site-nav a:last-child { display: none; }
    }
    @media (prefers-reduced-motion: reduce) {
      html { scroll-behavior: auto; }
      .button { transition: none; }
    }
  </style>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header shell">
    <a class="brand" href="/" aria-label="Anvil home">
      <span class="brand-mark" aria-hidden="true">
        <svg viewBox="0 0 40 40" role="presentation">
          <rect width="40" height="40" fill="#1c1b1a"/>
          <path d="M5 10c5-6 11-4 15 0s8 2 12 7c4 5 1 12-5 12-5 0-7-4-12-4C8 25 2 17 5 10Z" fill="#3aa99f"/>
          <path d="M2 31C11 27 17 28 22 22c5-6 9-9 16-12" fill="none" stroke="#4385be" stroke-width="3"/>
          <path d="m29 24-5 11 5-3 5 3Z" fill="#fffcf0" stroke="#100f0f" stroke-width="1.4"/>
        </svg>
      </span>
      <span>Anvil</span>
    </a>
    <nav class="site-nav" aria-label="Primary navigation">
      <a href="#capabilities">What it does</a>
      <a href="https://github.com/KeganHollern/radar-app">GitHub</a>
      <a href="https://lystic.dev">Lystic.dev</a>
    </nav>
  </header>

  <main id="main">
    <section class="hero shell" aria-labelledby="hero-title">
      <div class="hero-copy">
        <p class="eyebrow"><span class="live-dot" aria-hidden="true"></span>Live radar. No timeline.</p>
        <h1 id="hero-title">See what’s <span>ahead.</span></h1>
        <p class="lede">Anvil keeps current radar, active weather alerts, and your position together in one calm, glanceable map—built for the road, not the forecast cycle.</p>
        <div class="actions">
          <a class="button primary" href="https://github.com/KeganHollern/radar-app">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M8 9 4 12l4 3M16 9l4 3-4 3M14 5l-4 14"/></svg>
            View the source
          </a>
          <a class="button" href="https://lystic.dev">
            More from Lystic
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M5 12h14m-6-6 6 6-6 6"/></svg>
          </a>
        </div>
        <p class="live-only">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>
          Latest observations only. No forecast or historical playback.
        </p>
      </div>

      <div class="phone-stage">
        <figure class="phone-figure">
          <div class="phone" role="img" aria-label="Anvil app showing live radar, roads, the current location, and a tornado warning near Austin">
            <div class="screen">
              <svg class="screen-map" viewBox="0 0 256 540" preserveAspectRatio="none" aria-hidden="true">
                <defs>
                  <radialGradient id="stormGreen" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#d0a215" stop-opacity=".88"/><stop offset=".38" stop-color="#879a39" stop-opacity=".82"/><stop offset="1" stop-color="#3aa99f" stop-opacity="0"/></radialGradient>
                  <radialGradient id="stormRed" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#d14d41" stop-opacity=".92"/><stop offset=".45" stop-color="#da702c" stop-opacity=".82"/><stop offset="1" stop-color="#d0a215" stop-opacity="0"/></radialGradient>
                  <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#100f0f" stop-opacity=".16"/><stop offset="1" stop-color="#100f0f" stop-opacity=".48"/></linearGradient>
                </defs>
                <rect width="256" height="540" fill="#1c1b1a"/>
                <g fill="none" stroke="#403e3c" stroke-width="1.2" opacity=".8"><path d="M0 122 74 92l58 24 48-41 76 24M0 220l55-28 64 17 54-23 83 31M0 334l72-26 55 20 63-24 66 19M32 0l9 94-15 94 19 91-6 124 22 137M128 0l-5 81 17 104-10 94 14 124-6 137M220 0l-14 106 10 102-18 115 14 103-7 114"/></g>
                <g fill="none" stroke-linecap="round"><path d="M-10 435C46 377 84 356 119 296c34-57 75-90 147-134" stroke="#4385be" stroke-width="5"/><path d="M-12 431C45 374 82 353 116 293c34-57 74-89 146-133" stroke="#cecdc3" stroke-width="1.3"/><path d="M-8 156c52 23 105 31 160 13 36-12 69-11 112 1" stroke="#cecdc3" stroke-width="2.2" opacity=".7"/><path d="M14 510c29-78 47-120 90-168 38-42 70-81 89-153 14-51 28-98 59-144" stroke="#cecdc3" stroke-width="2.2" opacity=".64"/><path d="M-5 274c53-3 88 8 129 38 38 27 79 40 137 29" stroke="#cecdc3" stroke-width="1.8" opacity=".58"/></g>
                <ellipse cx="88" cy="238" rx="108" ry="104" fill="url(#stormGreen)" transform="rotate(-22 88 238)"/>
                <ellipse cx="58" cy="210" rx="64" ry="71" fill="url(#stormRed)" transform="rotate(-30 58 210)"/>
                <ellipse cx="190" cy="358" rx="97" ry="88" fill="url(#stormGreen)" transform="rotate(18 190 358)" opacity=".7"/>
                <path d="m36 180 62-18 44 73-34 55-68-31Z" fill="#d14d41" fill-opacity=".13" stroke="#d14d41" stroke-width="2.5"/>
                <rect width="256" height="540" fill="url(#fade)"/>
                <g fill="#cecdc3" font-family="system-ui, sans-serif" font-size="8" font-weight="650"><text x="151" y="267">AUSTIN</text><text x="116" y="346">San Marcos</text><text x="89" y="427">San Antonio</text><text x="178" y="119">Temple</text></g>
                <g fill="#878580"><circle cx="149" cy="270" r="2.3"/><circle cx="113" cy="348" r="1.8"/><circle cx="86" cy="429" r="2.1"/><circle cx="176" cy="121" r="1.8"/></g>
              </svg>
              <div class="island" aria-hidden="true"></div>
              <div class="status-bar" aria-hidden="true"><span>9:41</span><span class="status-icons">● ◒ <i></i></span></div>
              <div class="top-pill" aria-hidden="true"><span>Anvil</span><b>LIVE</b></div>
              <div class="map-control one" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="7"/><path d="M12 2v3m0 14v3M2 12h3m14 0h3"/></svg></div>
              <div class="map-control two" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 15.5A3.5 3.5 0 1 0 12 8a3.5 3.5 0 0 0 0 7.5Z"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-4v-.08A1.7 1.7 0 0 0 8.96 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.56-1.03H3v-4h.08A1.7 1.7 0 0 0 4.6 8.94a1.7 1.7 0 0 0-.34-1.88L4.2 7l2.83-2.83.06.06a1.7 1.7 0 0 0 1.88.34A1.7 1.7 0 0 0 10 3.01V3h4v.08a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06L19.8 7l-.06.06a1.7 1.7 0 0 0-.34 1.88A1.7 1.7 0 0 0 20.96 10H21v4h-.08A1.7 1.7 0 0 0 19.4 15Z"/></svg></div>
              <div class="location" aria-hidden="true"></div>
              <div class="alert-chip" aria-hidden="true"><i></i><span>Tornado Warning · until 10:15 PM</span></div>
              <div class="legend" aria-hidden="true"><div class="legend-labels"><span>Light</span><span>Reflectivity</span><span>Heavy</span></div><div class="legend-bar"></div></div>
              <div class="home-indicator" aria-hidden="true"></div>
            </div>
          </div>
          <figcaption>Nearby mode follows your position while preserving the view you chose.</figcaption>
        </figure>
      </div>
    </section>

    <section class="features shell" id="capabilities" aria-label="Anvil capabilities">
      <article class="feature"><span class="feature-number">01 / NOW</span><h2>Current radar only</h2><p>A live multi-radar view with station reflectivity and radial velocity when you need more detail.</p></article>
      <article class="feature"><span class="feature-number">02 / FOLLOW</span><h2>Built around your position</h2><p>Pin the map to keep yourself centered without losing the zoom level that matters on the road.</p></article>
      <article class="feature"><span class="feature-number">03 / ALERT</span><h2>Warnings on the map</h2><p>Active NWS alert areas appear in context, with clear details and controls for the alert types you want.</p></article>
    </section>

    <section class="open-source shell" aria-labelledby="open-title">
      <div><h2 id="open-title">Weather software, built in the open.</h2><p>Anvil is a Flutter and Go project powered by current NOAA and National Weather Service data. Inspect the architecture, follow the work, or make it better.</p></div>
      <a class="button" href="https://github.com/KeganHollern/radar-app">Explore on GitHub <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M5 12h14m-6-6 6 6-6 6"/></svg></a>
    </section>
  </main>

  <footer class="site-footer shell">
    <span>© Lystic · Live weather awareness, without the timeline.</span>
    <span>Data from <a href="https://www.noaa.gov">NOAA</a> and the <a href="https://www.weather.gov">National Weather Service</a>.</span>
  </footer>
</body>
</html>`
