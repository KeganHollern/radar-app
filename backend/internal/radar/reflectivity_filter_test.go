package radar

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func TestWeakReflectivityColorUsesFifteenDBZFloor(t *testing.T) {
	tests := []struct {
		name  string
		want  bool
		red   uint8
		green uint8
		blue  uint8
	}{
		{name: "negative dBZ pale return", want: true, red: 0xa4, green: 0xab, blue: 0xb5},
		{name: "eight dBZ blue return", want: true, red: 0x49, green: 0x6f, blue: 0xaa},
		{name: "ten dBZ return", want: true, red: 0x54, green: 0x8f, blue: 0xbd},
		{name: "fourteen dBZ return", want: true, red: 0x59, green: 0xbe, blue: 0xbc},
		{name: "fifteen dBZ threshold", want: false, red: 0x57, green: 0xc7, blue: 0xb3},
		{name: "sixteen dBZ cutoff", want: false, red: 0x54, green: 0xcf, blue: 0xaa},
		{name: "moderate green return", want: false, red: 0x28, green: 0xd6, blue: 0x4a},
		{name: "strong white return", want: false, red: 0xff, green: 0xff, blue: 0xff},
		{name: "unknown color fails open", want: false, red: 0x10, green: 0x10, blue: 0x10},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isWeakReflectivityColor(test.red, test.green, test.blue); got != test.want {
				t.Fatalf("isWeakReflectivityColor(%d, %d, %d) = %t, want %t", test.red, test.green, test.blue, got, test.want)
			}
		})
	}
}

func TestFilterStationReflectivityTile(t *testing.T) {
	input := image.NewNRGBA(image.Rect(0, 0, 9, 1))
	pixels := []color.NRGBA{
		{R: 0xff, G: 0xff, B: 0xff, A: 0},
		{R: 0xa4, G: 0xab, B: 0xb5, A: 0xff},
		{R: 0x49, G: 0x6f, B: 0xaa, A: 0xff},
		{R: 0x54, G: 0x8f, B: 0xbd, A: 0xff},
		{R: 0x59, G: 0xbe, B: 0xbc, A: 0xff},
		{R: 0x54, G: 0xcf, B: 0xaa, A: 0xff},
		{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff},
		{R: 0xff, G: 0xff, B: 0xff, A: 0xff},
		{R: 0x10, G: 0x10, B: 0x10, A: 0xff},
	}
	for x, pixel := range pixels {
		input.SetNRGBA(x, 0, pixel)
	}
	body := encodePNG(t, input)

	filteredBody, err := filterStationReflectivityTile("reflectivity", body)
	if err != nil {
		t.Fatal(err)
	}
	filtered, err := png.Decode(bytes.NewReader(filteredBody))
	if err != nil {
		t.Fatal(err)
	}

	for _, x := range []int{0, 1, 2, 3, 4} {
		_, _, _, alpha := filtered.At(x, 0).RGBA()
		if alpha != 0 {
			t.Errorf("pixel %d alpha = %d, want transparent", x, alpha)
		}
	}
	for _, x := range []int{5, 6, 7, 8} {
		got := color.NRGBAModel.Convert(filtered.At(x, 0)).(color.NRGBA)
		if got != pixels[x] {
			t.Errorf("pixel %d = %#v, want %#v", x, got, pixels[x])
		}
	}
}

func TestStationReflectivityFilterDoesNotTouchOtherProducts(t *testing.T) {
	body := []byte("not even a PNG")
	for _, product := range []string{"aggregate", "velocity"} {
		got, err := filterStationReflectivityTile(product, body)
		if err != nil {
			t.Fatalf("%s: %v", product, err)
		}
		if len(got) == 0 || &got[0] != &body[0] {
			t.Fatalf("%s tile was not returned unchanged", product)
		}
	}
}

func TestStationReflectivityFilterRejectsInvalidPNG(t *testing.T) {
	if _, err := filterStationReflectivityTile("reflectivity", []byte("not a PNG")); err == nil {
		t.Fatal("expected invalid PNG error")
	}
}

func encodePNG(t *testing.T, source image.Image) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := png.Encode(&output, source); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
