package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/config"
)

func landingTestHandler() http.Handler {
	c := config.Config{
		AllowedOrigins:   []string{"*"},
		UserAgent:        "radar-test",
		UpstreamTimeout:  time.Second,
		StaleTTL:         time.Minute,
		CacheMaxEntries:  8,
		CacheMaxBytes:    1 << 20,
		MaxUpstreamBytes: 1 << 20,
		TileMaxZoom:      16,
		Reflectivity:     map[string]string{"0.5": "sr_bref"},
		Velocity:         map[string]string{"0.5": "sr_bvel"},
	}
	return New(c, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()
}

func TestLandingPage(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()
	landingTestHandler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}
	if got := response.Header().Get("Cache-Control"); got != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if got := response.Header().Get("Content-Length"); got != strconv.Itoa(len(landingPage)) {
		t.Fatalf("Content-Length = %q, want %d", got, len(landingPage))
	}
	if response.Header().Get("ETag") == "" {
		t.Fatal("landing page must have an ETag")
	}

	body := response.Body.String()
	wants := []string{
		`<!doctype html>`,
		`<html lang="en">`,
		`<meta name="viewport"`,
		`<title>HyprRadar — Live weather radar</title>`,
		`<main id="main">`,
		`href="#main">Skip to content</a>`,
		`aria-label="Primary navigation"`,
		`role="img" aria-label="HyprRadar app showing live radar`,
		`href="https://github.com/KeganHollern/radar-app"`,
		`href="https://lystic.dev"`,
		`Live radar. No timeline.`,
		`Current radar only`,
		`Warnings on the map`,
	}
	for _, want := range wants {
		if !strings.Contains(body, want) {
			t.Errorf("landing page does not contain %q", want)
		}
	}
	if strings.Contains(body, `<script`) || strings.Contains(body, `<link rel="stylesheet"`) || strings.Contains(body, `src="http`) {
		t.Fatal("landing page must not depend on external scripts, stylesheets, or images")
	}
}

func TestLandingPageSecurityHeaders(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()
	landingTestHandler().ServeHTTP(response, request)

	wants := map[string]string{
		"X-Content-Type-Options":       "nosniff",
		"Referrer-Policy":              "no-referrer",
		"X-Frame-Options":              "DENY",
		"Cross-Origin-Opener-Policy":   "same-origin",
		"Cross-Origin-Resource-Policy": "same-origin",
	}
	for name, want := range wants {
		if got := response.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	csp := response.Header().Get("Content-Security-Policy")
	for _, directive := range []string{"default-src 'none'", "base-uri 'none'", "frame-ancestors 'none'", "object-src 'none'"} {
		if !strings.Contains(csp, directive) {
			t.Errorf("Content-Security-Policy %q does not contain %q", csp, directive)
		}
	}
	if got := response.Header().Get("Permissions-Policy"); !strings.Contains(got, "geolocation=()") || !strings.Contains(got, "camera=()") {
		t.Errorf("Permissions-Policy = %q", got)
	}
}

func TestLandingPageHeadAndConditionalGet(t *testing.T) {
	handler := landingTestHandler()

	head := httptest.NewRecorder()
	handler.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD response = %d, %q", head.Code, head.Body.String())
	}
	if got := head.Header().Get("Content-Length"); got != strconv.Itoa(len(landingPage)) {
		t.Fatalf("HEAD Content-Length = %q, want %d", got, len(landingPage))
	}

	conditionalRequest := httptest.NewRequest(http.MethodGet, "/", nil)
	conditionalRequest.Header.Set("If-None-Match", head.Header().Get("ETag"))
	conditional := httptest.NewRecorder()
	handler.ServeHTTP(conditional, conditionalRequest)
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Fatalf("conditional response = %d, %q", conditional.Code, conditional.Body.String())
	}
}

func TestLandingPageMethodAndRouteIsolation(t *testing.T) {
	handler := landingTestHandler()

	post := httptest.NewRecorder()
	handler.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/", nil))
	if post.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST / status = %d, want 405", post.Code)
	}
	allow := post.Header().Get("Allow")
	if !strings.Contains(allow, http.MethodGet) || !strings.Contains(allow, http.MethodHead) {
		t.Fatalf("POST / Allow = %q", allow)
	}

	missing := httptest.NewRecorder()
	handler.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/not-a-page", nil))
	if missing.Code != http.StatusNotFound || strings.Contains(missing.Body.String(), "See what’s") {
		t.Fatalf("unknown route = %d, %q", missing.Code, missing.Body.String())
	}

	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if health.Code != http.StatusOK || health.Header().Get("Content-Type") != "application/json" || !strings.Contains(health.Body.String(), `"status":"ok"`) {
		t.Fatalf("health response changed: %d %q %#v", health.Code, health.Body.String(), health.Header())
	}

	options := httptest.NewRecorder()
	handler.ServeHTTP(options, httptest.NewRequest(http.MethodOptions, "/", nil))
	if options.Code != http.StatusNoContent || options.Body.Len() != 0 {
		t.Fatalf("OPTIONS response = %d, %q", options.Code, options.Body.String())
	}
}
