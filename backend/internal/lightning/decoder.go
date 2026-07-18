package lightning

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"reflect"
	"strings"
	"time"

	"github.com/batchatco/go-native-netcdf/netcdf"
	"github.com/batchatco/go-native-netcdf/netcdf/api"
)

type Decoder interface {
	Decode(body []byte, object Object, receivedAt time.Time) ([]Flash, error)
}

type NetCDFDecoder struct {
	MaxFlashes    int
	SeamLongitude float64
}

func (d NetCDFDecoder) Decode(body []byte, object Object, receivedAt time.Time) (flashes []Flash, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("decode NetCDF: %v", recovered)
			flashes = nil
		}
	}()
	if len(body) == 0 {
		return nil, errors.New("decode NetCDF: empty object")
	}
	maxFlashes := d.MaxFlashes
	if maxFlashes <= 0 {
		maxFlashes = 20000
	}
	reader := &readSeekCloser{Reader: bytes.NewReader(body)}
	group, err := netcdf.New(reader)
	if err != nil {
		return nil, fmt.Errorf("decode NetCDF container: %w", err)
	}
	defer group.Close()

	ids, idAttributes, err := variableValues(group, "flash_id", maxFlashes)
	if err != nil {
		return nil, err
	}
	latitudes, latitudeAttributes, err := variableValues(group, "flash_lat", maxFlashes)
	if err != nil {
		return nil, err
	}
	longitudes, longitudeAttributes, err := variableValues(group, "flash_lon", maxFlashes)
	if err != nil {
		return nil, err
	}
	qualities, qualityAttributes, err := variableValues(group, "flash_quality_flag", maxFlashes)
	if err != nil {
		return nil, err
	}
	offsets, offsetAttributes, err := variableValues(group, "flash_time_offset_of_last_event", maxFlashes)
	if err != nil {
		return nil, err
	}

	length := sliceLength(ids)
	if length < 0 || sliceLength(latitudes) != length || sliceLength(longitudes) != length || sliceLength(qualities) != length || sliceLength(offsets) != length {
		return nil, errors.New("decode NetCDF: flash variables have inconsistent lengths")
	}
	baseTime, scale, addOffset, unsigned, err := timeEncoding(offsetAttributes)
	if err != nil {
		return nil, fmt.Errorf("decode flash time: %w", err)
	}
	return d.decodeRows(object, receivedAt, rowValues{
		ids:                 ids,
		idAttributes:        idAttributes,
		latitudes:           latitudes,
		latitudeAttributes:  latitudeAttributes,
		longitudes:          longitudes,
		longitudeAttributes: longitudeAttributes,
		qualities:           qualities,
		qualityAttributes:   qualityAttributes,
		offsets:             offsets,
		offsetAttributes:    offsetAttributes,
		baseTime:            baseTime,
		scale:               scale,
		addOffset:           addOffset,
		unsignedOffset:      unsigned || signedIntegerStorage(offsets),
		unsignedID:          attributeIsTrue(idAttributes, "_Unsigned") || signedIntegerStorage(ids),
	}), nil
}

type rowValues struct {
	ids                 any
	idAttributes        api.AttributeMap
	latitudes           any
	latitudeAttributes  api.AttributeMap
	longitudes          any
	longitudeAttributes api.AttributeMap
	qualities           any
	qualityAttributes   api.AttributeMap
	offsets             any
	offsetAttributes    api.AttributeMap
	baseTime            time.Time
	scale               float64
	addOffset           float64
	unsignedOffset      bool
	unsignedID          bool
}

func (d NetCDFDecoder) decodeRows(object Object, receivedAt time.Time, values rowValues) []Flash {
	length := sliceLength(values.ids)
	receivedAt = receivedAt.UTC()
	result := make([]Flash, 0, length)
	for index := 0; index < length; index++ {
		quality, ok := validatedNumericAt(values.qualities, values.qualityAttributes, index, false)
		if !ok || quality != 0 {
			continue
		}
		latitude, latOK := validatedNumericAt(values.latitudes, values.latitudeAttributes, index, false)
		longitude, lonOK := validatedNumericAt(values.longitudes, values.longitudeAttributes, index, false)
		if !latOK || !lonOK || !finite(latitude) || !finite(longitude) || latitude < -90 || latitude > 90 {
			continue
		}
		longitude = normalizeLongitude(longitude)
		if !finite(longitude) || longitude < -180 || longitude > 180 || !d.belongsToSatellite(object.Satellite, longitude) {
			continue
		}
		offset, ok := validatedNumericAt(values.offsets, values.offsetAttributes, index, values.unsignedOffset)
		if !ok || !finite(offset) {
			continue
		}
		seconds := offset*values.scale + values.addOffset
		if !finite(seconds) || math.Abs(seconds) > float64(24*time.Hour/time.Second) {
			continue
		}
		observedAt := values.baseTime.Add(time.Duration(seconds * float64(time.Second))).UTC()
		if observedAt.Before(object.Start.Add(-5*time.Second)) || observedAt.After(object.End.Add(5*time.Second)) {
			continue
		}
		identifier, ok := validatedIntegerAt(values.ids, values.idAttributes, index, values.unsignedID)
		if !ok {
			continue
		}
		stableID := stableFlashID(object.Satellite, object.Key, identifier)
		result = append(result, Flash{
			ID:         stableID,
			Latitude:   latitude,
			Longitude:  longitude,
			ObservedAt: observedAt,
			ReceivedAt: receivedAt,
			Satellite:  SatelliteName(object.Satellite),
		})
	}
	return result
}

func (d NetCDFDecoder) belongsToSatellite(satellite string, longitude float64) bool {
	seam := d.SeamLongitude
	if !finite(seam) || seam < -130 || seam > -80 {
		seam = -105
	}
	opposite := oppositeSeam(seam)
	switch satellite {
	case EastSourceID:
		return longitude >= seam && longitude < opposite
	case WestSourceID:
		return longitude < seam || longitude >= opposite
	default:
		return false
	}
}

func variableValues(group api.Group, name string, maxLength int) (any, api.AttributeMap, error) {
	getter, err := group.GetVarGetter(name)
	if err != nil {
		return nil, nil, fmt.Errorf("decode NetCDF variable %s: %w", name, err)
	}
	if getter.Len() < 0 || getter.Len() > int64(maxLength) {
		return nil, nil, fmt.Errorf("decode NetCDF variable %s: length %d exceeds limit %d", name, getter.Len(), maxLength)
	}
	values, err := getter.Values()
	if err != nil {
		return nil, nil, fmt.Errorf("decode NetCDF variable %s values: %w", name, err)
	}
	return values, getter.Attributes(), nil
}

func timeEncoding(attributes api.AttributeMap) (time.Time, float64, float64, bool, error) {
	unitsValue, ok := attributes.Get("units")
	if !ok {
		return time.Time{}, 0, 0, false, errors.New("missing units attribute")
	}
	units, ok := unitsValue.(string)
	if !ok || !strings.HasPrefix(units, "seconds since ") {
		return time.Time{}, 0, 0, false, errors.New("unsupported units attribute")
	}
	baseRaw := strings.TrimSpace(strings.TrimPrefix(units, "seconds since "))
	base, err := parseNetCDFBaseTime(baseRaw)
	if err != nil {
		return time.Time{}, 0, 0, false, err
	}
	scale, ok := numericAttribute(attributes, "scale_factor")
	if !ok || !finite(scale) || scale <= 0 {
		return time.Time{}, 0, 0, false, errors.New("invalid scale_factor attribute")
	}
	offset, ok := numericAttribute(attributes, "add_offset")
	if !ok || !finite(offset) {
		return time.Time{}, 0, 0, false, errors.New("invalid add_offset attribute")
	}
	return base, scale, offset, attributeIsTrue(attributes, "_Unsigned"), nil
}

func parseNetCDFBaseTime(raw string) (time.Time, error) {
	for _, layout := range []string{
		"2006-01-02 15:04:05.999999999",
		"2006-01-02T15:04:05.999999999Z",
		time.RFC3339Nano,
	} {
		if parsed, err := time.Parse(layout, raw); err == nil {
			return parsed.UTC(), nil
		}
	}
	return time.Time{}, errors.New("invalid time origin in units attribute")
}

func numericAttribute(attributes api.AttributeMap, name string) (float64, bool) {
	if attributes == nil {
		return 0, false
	}
	value, ok := attributes.Get(name)
	if !ok {
		return 0, false
	}
	if length := sliceLength(value); length == 1 {
		return numericAt(value, 0, false)
	}
	return numericScalar(value)
}

func attributeIsTrue(attributes api.AttributeMap, name string) bool {
	if attributes == nil {
		return false
	}
	value, ok := attributes.Get(name)
	if !ok {
		return false
	}
	text, ok := value.(string)
	return ok && strings.EqualFold(strings.TrimSpace(text), "true")
}

func sliceLength(values any) int {
	if values == nil {
		return -1
	}
	value := reflect.ValueOf(values)
	if value.Kind() != reflect.Slice && value.Kind() != reflect.Array {
		return -1
	}
	return value.Len()
}

func numericAt(values any, index int, unsigned bool) (float64, bool) {
	value := reflect.ValueOf(values)
	if (value.Kind() != reflect.Slice && value.Kind() != reflect.Array) || index < 0 || index >= value.Len() {
		return 0, false
	}
	item := value.Index(index)
	switch item.Kind() {
	case reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64, reflect.Int:
		if unsigned {
			bits := item.Type().Bits()
			signed := item.Int()
			switch bits {
			case 8:
				return float64(uint8(signed)), true
			case 16:
				return float64(uint16(signed)), true
			case 32:
				return float64(uint32(signed)), true
			case 64:
				return float64(uint64(signed)), true
			}
		}
		return float64(item.Int()), true
	case reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uint:
		return float64(item.Uint()), true
	case reflect.Float32, reflect.Float64:
		return item.Float(), true
	default:
		return 0, false
	}
}

func validatedNumericAt(values any, attributes api.AttributeMap, index int, unsigned bool) (float64, bool) {
	raw, ok := numericAt(values, index, false)
	if !ok {
		return 0, false
	}
	if fill, present, valid := numericAttributeValue(attributes, "_FillValue", false); present && (!valid || sameNumber(raw, fill)) {
		return 0, false
	}
	value, ok := numericAt(values, index, unsigned)
	if !ok || !finite(value) {
		return 0, false
	}
	if attributes == nil {
		return value, true
	}
	if rawRange, present := attributes.Get("valid_range"); present {
		if sliceLength(rawRange) != 2 {
			return 0, false
		}
		minimum, minimumOK := numericAt(rawRange, 0, unsigned)
		maximum, maximumOK := numericAt(rawRange, 1, unsigned)
		if !minimumOK || !maximumOK || !finite(minimum) || !finite(maximum) || minimum > maximum || value < minimum || value > maximum {
			return 0, false
		}
	}
	if minimum, present, valid := numericAttributeValue(attributes, "valid_min", unsigned); present && (!valid || value < minimum) {
		return 0, false
	}
	if maximum, present, valid := numericAttributeValue(attributes, "valid_max", unsigned); present && (!valid || value > maximum) {
		return 0, false
	}
	return value, true
}

func numericAttributeValue(attributes api.AttributeMap, name string, unsigned bool) (float64, bool, bool) {
	if attributes == nil {
		return 0, false, false
	}
	raw, present := attributes.Get(name)
	if !present {
		return 0, false, false
	}
	if length := sliceLength(raw); length == 1 {
		value, ok := numericAt(raw, 0, unsigned)
		return value, true, ok && finite(value)
	}
	value, ok := numericScalar(raw)
	return value, true, ok && finite(value)
}

func sameNumber(first, second float64) bool {
	return first == second || (math.IsNaN(first) && math.IsNaN(second))
}

func signedIntegerStorage(values any) bool {
	typeOf := reflect.TypeOf(values)
	if typeOf == nil || (typeOf.Kind() != reflect.Slice && typeOf.Kind() != reflect.Array) {
		return false
	}
	switch typeOf.Elem().Kind() {
	case reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64, reflect.Int:
		return true
	default:
		return false
	}
}

func validatedIntegerAt(values any, attributes api.AttributeMap, index int, unsigned bool) (uint64, bool) {
	number, ok := validatedNumericAt(values, attributes, index, unsigned)
	if !ok || number < 0 || math.Trunc(number) != number || number > math.MaxUint64 {
		return 0, false
	}
	return uint64(number), true
}

func numericScalar(value any) (float64, bool) {
	reflected := reflect.ValueOf(value)
	switch reflected.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return float64(reflected.Int()), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return float64(reflected.Uint()), true
	case reflect.Float32, reflect.Float64:
		return reflected.Float(), true
	default:
		return 0, false
	}
}

func normalizeLongitude(longitude float64) float64 {
	if !finite(longitude) || math.Abs(longitude) > 360 {
		return math.NaN()
	}
	longitude = math.Mod(longitude, 360)
	if longitude > 180 {
		longitude -= 360
	} else if longitude < -180 {
		longitude += 360
	}
	return longitude
}

func stableFlashID(satellite, objectKey string, id uint64) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%d", satellite, objectKey, id)))
	return "glm-" + hex.EncodeToString(hash[:12])
}

func finite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

type readSeekCloser struct {
	*bytes.Reader
}

func (*readSeekCloser) Close() error { return nil }

var _ io.ReadSeekCloser = (*readSeekCloser)(nil)
