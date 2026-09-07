package api

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestPrivacyPageIsPublicAndComplete(t *testing.T) {
	response := httptest.NewRecorder()
	landingTestHandler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/privacy", nil))

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}
	if got := response.Header().Get("Content-Length"); got != strconv.Itoa(len(privacyPage)) {
		t.Fatalf("Content-Length = %q, want %d", got, len(privacyPage))
	}
	if response.Header().Get("ETag") == "" {
		t.Fatal("privacy page must have an ETag")
	}
	for _, want := range []string{
		"HyprRadar Privacy Policy",
		"Kegan Hollern",
		"keganhollern@gmail.com",
		"Optional background location",
		"roughly 100-meter precision",
		"HTTPS POST request body",
		"actively purged",
		"raw ingress access logging is disabled",
		"Retention and deletion",
		"We do not sell personal data",
	} {
		if !strings.Contains(response.Body.String(), want) {
			t.Errorf("privacy page does not contain %q", want)
		}
	}
	if strings.Contains(response.Body.String(), "<script") || strings.Contains(response.Body.String(), `<link rel="stylesheet"`) {
		t.Fatal("privacy page must not rely on active or external page assets")
	}
}

func TestPrivacyPageSecurityHeadAndConditionalGet(t *testing.T) {
	handler := landingTestHandler()
	head := httptest.NewRecorder()
	handler.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/privacy", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD response = %d, %q", head.Code, head.Body.String())
	}
	for name, want := range map[string]string{
		"X-Content-Type-Options":       "nosniff",
		"Referrer-Policy":              "no-referrer",
		"X-Frame-Options":              "DENY",
		"Cross-Origin-Opener-Policy":   "same-origin",
		"Cross-Origin-Resource-Policy": "same-origin",
	} {
		if got := head.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if !strings.Contains(head.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("missing restrictive CSP: %q", head.Header().Get("Content-Security-Policy"))
	}

	conditionalRequest := httptest.NewRequest(http.MethodGet, "/privacy", nil)
	conditionalRequest.Header.Set("If-None-Match", head.Header().Get("ETag"))
	conditional := httptest.NewRecorder()
	handler.ServeHTTP(conditional, conditionalRequest)
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Fatalf("conditional response = %d, %q", conditional.Code, conditional.Body.String())
	}
}
