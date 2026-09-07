package radar

import "testing"

func TestValidateStationCatalog(t *testing.T) {
	valid := `{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-97.3,35.3]},"properties":{"rda_id":"KTLX"}}]}`
	for _, test := range []struct {
		name    string
		body    string
		wantErr bool
	}{
		{name: "valid", body: valid},
		{name: "not GeoJSON", body: `{}`, wantErr: true},
		{name: "empty", body: `{"type":"FeatureCollection","features":[]}`, wantErr: true},
		{name: "invalid coordinate", body: `{"type":"FeatureCollection","features":[{"geometry":{"type":"Point","coordinates":[-197,35]},"properties":{"rda_id":"KTLX"}}]}`, wantErr: true},
		{name: "unsupported station", body: `{"type":"FeatureCollection","features":[{"geometry":{"type":"Point","coordinates":[-97,35]},"properties":{"rda_id":"TEST"}}]}`, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := ValidateStationCatalog([]byte(test.body))
			if (err != nil) != test.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, test.wantErr)
			}
		})
	}
}
