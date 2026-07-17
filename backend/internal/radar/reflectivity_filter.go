package radar

import (
	"bytes"
	"fmt"
	"image"
	"image/draw"
	"image/png"
)

// reflectivityFloorDBZ is a presentation threshold, not meteorological quality
// control. NOAA notes that measurable precipitation is generally near 15 dBZ
// or greater, making that a reasonable floor for the rain-focused view. Apply
// the same floor to station and aggregate reflectivity so switching modes does
// not reveal a second field of weak echoes from the regional mosaic.
const reflectivityFloorDBZ = 15

const maxPaletteDistanceSquared = 32 * 32

type reflectivityPaletteSample struct {
	dbz     int
	r, g, b uint8
}

// NOAA publishes the RIDGE reflectivity layers as pre-colored RGBA rasters
// rather than numeric reflectivity tiles. The station SR_BREF and regional
// BREF.QCD products use the same color progression. These samples are taken
// every 2 dBZ from the official SR_BREF WMS legend (-28 through 70 dBZ), with
// the final endpoint included. Unknown colors fail open and remain visible.
var reflectivityPalette = []reflectivityPaletteSample{
	{-28, 0x8d, 0x81, 0x7f}, {-26, 0x91, 0x88, 0x6d},
	{-24, 0x94, 0x8e, 0x5b}, {-22, 0x9c, 0x98, 0x5e},
	{-20, 0xa7, 0xa5, 0x71}, {-18, 0xb3, 0xb3, 0x84},
	{-16, 0xbf, 0xc0, 0x98}, {-14, 0xcc, 0xce, 0xab},
	{-12, 0xcb, 0xcd, 0xb4}, {-10, 0xbd, 0xc1, 0xb4},
	{-8, 0xaf, 0xb6, 0xb4}, {-6, 0xa4, 0xab, 0xb5},
	{-4, 0x99, 0xa0, 0xb5}, {-2, 0x89, 0x93, 0xb2},
	{0, 0x76, 0x84, 0xad}, {2, 0x62, 0x76, 0xa8},
	{4, 0x56, 0x6c, 0xa4}, {6, 0x49, 0x62, 0xa1},
	{8, 0x49, 0x6f, 0xaa}, {10, 0x54, 0x8f, 0xbd},
	{12, 0x5e, 0xae, 0xce}, {14, 0x59, 0xbe, 0xbc},
	{16, 0x54, 0xcf, 0xaa}, {18, 0x43, 0xd6, 0x83},
	{20, 0x28, 0xd6, 0x4a}, {22, 0x0e, 0xd5, 0x14},
	{24, 0x0d, 0xb5, 0x12}, {26, 0x0c, 0x96, 0x10},
	{28, 0x0b, 0x7f, 0x0e}, {30, 0x0a, 0x6e, 0x0b},
	{32, 0x0e, 0x61, 0x09}, {34, 0x70, 0x96, 0x05},
	{36, 0xd3, 0xca, 0x02}, {38, 0xfa, 0xd8, 0x0a},
	{40, 0xf2, 0xc5, 0x1d}, {42, 0xeb, 0xb3, 0x2d},
	{44, 0xf3, 0xb2, 0x1b}, {46, 0xfb, 0xb1, 0x08},
	{48, 0xeb, 0x04, 0x04}, {50, 0xc5, 0x0a, 0x0b},
	{52, 0xa2, 0x10, 0x11}, {54, 0xa8, 0x09, 0x0a},
	{56, 0xae, 0x03, 0x03}, {58, 0xf9, 0xe1, 0xfe},
	{60, 0xee, 0xa9, 0xfd}, {62, 0xe4, 0x74, 0xfc},
	{64, 0xef, 0x74, 0xfd}, {66, 0xfa, 0x75, 0xff},
	{68, 0x9a, 0x00, 0xf3}, {70, 0x79, 0x00, 0xe2},
	{72, 0x5b, 0x00, 0xd3},
}

func filterStationReflectivityTile(product string, body []byte) ([]byte, error) {
	if product != "reflectivity" {
		return body, nil
	}
	return filterReflectivityTile(body)
}

func filterReflectivityTile(body []byte) ([]byte, error) {
	source, err := png.Decode(bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("decode PNG: %w", err)
	}
	bounds := source.Bounds()
	filtered := image.NewNRGBA(bounds)
	draw.Draw(filtered, bounds, source, bounds.Min, draw.Src)

	decisions := make(map[uint32]bool)
	changed := false
	for offset := 0; offset < len(filtered.Pix); offset += 4 {
		alpha := filtered.Pix[offset+3]
		if alpha == 0 {
			continue
		}
		red := filtered.Pix[offset]
		green := filtered.Pix[offset+1]
		blue := filtered.Pix[offset+2]
		key := uint32(red)<<16 | uint32(green)<<8 | uint32(blue)
		weak, ok := decisions[key]
		if !ok {
			weak = isWeakReflectivityColor(red, green, blue)
			decisions[key] = weak
		}
		if weak {
			filtered.Pix[offset] = 0
			filtered.Pix[offset+1] = 0
			filtered.Pix[offset+2] = 0
			filtered.Pix[offset+3] = 0
			changed = true
		}
	}
	if !changed {
		return body, nil
	}

	var output bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&output, filtered); err != nil {
		return nil, fmt.Errorf("encode PNG: %w", err)
	}
	return output.Bytes(), nil
}

func isWeakReflectivityColor(red, green, blue uint8) bool {
	closestDBZ := 0
	closestDistance := int(^uint(0) >> 1)
	for _, sample := range reflectivityPalette {
		distance := colorDistanceSquared(red, green, blue, sample)
		if distance < closestDistance {
			closestDistance = distance
			closestDBZ = sample.dbz
		}
	}
	return closestDistance <= maxPaletteDistanceSquared && closestDBZ < reflectivityFloorDBZ
}

func colorDistanceSquared(red, green, blue uint8, sample reflectivityPaletteSample) int {
	r := int(red) - int(sample.r)
	g := int(green) - int(sample.g)
	b := int(blue) - int(sample.b)
	return r*r + g*g + b*b
}
