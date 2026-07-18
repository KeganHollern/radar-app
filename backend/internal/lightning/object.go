package lightning

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

var objectKeyPattern = regexp.MustCompile(`^GLM-L2-LCFA/(\d{4})/(\d{3})/(\d{2})/OR_GLM-L2-LCFA_(G\d{2})_s(\d{14})_e(\d{14})_c(\d{14})\.nc$`)

type Object struct {
	Key       string
	Satellite string
	Start     time.Time
	End       time.Time
	Created   time.Time
}

func ParseObjectKey(key, expectedSatellite string) (Object, error) {
	matches := objectKeyPattern.FindStringSubmatch(key)
	if matches == nil {
		return Object{}, errors.New("object key is not an exact GLM-L2-LCFA key")
	}
	if expectedSatellite != "" && matches[4] != expectedSatellite {
		return Object{}, fmt.Errorf("object satellite %q does not match source %q", matches[4], expectedSatellite)
	}
	start, err := parseGOESTime(matches[5])
	if err != nil {
		return Object{}, fmt.Errorf("parse object start: %w", err)
	}
	end, err := parseGOESTime(matches[6])
	if err != nil {
		return Object{}, fmt.Errorf("parse object end: %w", err)
	}
	created, err := parseGOESTime(matches[7])
	if err != nil {
		return Object{}, fmt.Errorf("parse object creation: %w", err)
	}
	if matches[1] != start.Format("2006") || matches[2] != fmt.Sprintf("%03d", start.YearDay()) || matches[3] != start.Format("15") {
		return Object{}, errors.New("object prefix does not match its start time")
	}
	if !end.After(start) || end.Sub(start) > 30*time.Second {
		return Object{}, errors.New("object observation window is invalid")
	}
	if created.Before(end.Add(-5*time.Second)) || created.After(end.Add(2*time.Minute)) {
		return Object{}, errors.New("object creation time is invalid")
	}
	return Object{Key: key, Satellite: matches[4], Start: start, End: end, Created: created}, nil
}

func parseGOESTime(raw string) (time.Time, error) {
	if len(raw) != 14 {
		return time.Time{}, errors.New("GOES timestamp must have 14 digits")
	}
	for _, character := range raw {
		if character < '0' || character > '9' {
			return time.Time{}, errors.New("GOES timestamp must contain only digits")
		}
	}
	year, _ := strconv.Atoi(raw[0:4])
	day, _ := strconv.Atoi(raw[4:7])
	hour, _ := strconv.Atoi(raw[7:9])
	minute, _ := strconv.Atoi(raw[9:11])
	second, _ := strconv.Atoi(raw[11:13])
	tenth, _ := strconv.Atoi(raw[13:14])
	if year < 2000 || year > 2200 || day < 1 || day > 366 || hour > 23 || minute > 59 || second > 60 {
		return time.Time{}, errors.New("GOES timestamp is outside valid ranges")
	}
	base := time.Date(year, time.January, 1, hour, minute, 0, 0, time.UTC).AddDate(0, 0, day-1)
	if base.Year() != year {
		return time.Time{}, errors.New("GOES day-of-year is invalid for year")
	}
	return base.Add(time.Duration(second)*time.Second + time.Duration(tenth)*100*time.Millisecond), nil
}

func SatelliteName(id string) string {
	switch id {
	case "G19":
		return "GOES-19"
	case "G18":
		return "GOES-18"
	default:
		return id
	}
}
