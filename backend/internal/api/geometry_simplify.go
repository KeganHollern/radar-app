package api

import "math"

// zoneSimplifyToleranceDegrees is about 0.5 miles north/south. Zone-derived
// county and forecast boundaries are contextual warning fills, so this bounded
// tolerance removes survey-level detail that is not useful on a driving map.
// Inline alert polygons are never passed through this simplifier.
const zoneSimplifyToleranceDegrees = 0.0075

func simplifyMultiPolygon(value multiPolygon, tolerance float64) multiPolygon {
	result := make(multiPolygon, 0, len(value))
	for _, item := range value {
		result = append(result, simplifyPolygon(item, tolerance))
	}
	return result
}

func simplifyPolygon(value polygon, tolerance float64) polygon {
	result := make(polygon, 0, len(value))
	for _, ring := range value {
		result = append(result, simplifyRing(ring, tolerance))
	}
	return result
}

func simplifyRing(value linearRing, tolerance float64) linearRing {
	normalized := normalizeRing(value)
	if len(normalized) <= 4 || tolerance <= 0 {
		return normalized
	}

	// Work on the unique vertices, then split the closed loop at a distant
	// anchor. Simplifying both paths avoids treating the arbitrary first vertex
	// and its duplicate closing vertex as a zero-length baseline.
	vertices := normalized[:len(normalized)-1]
	anchor := 1
	maxDistance := -1.0
	for i := 1; i < len(vertices); i++ {
		dx := vertices[i][0] - vertices[0][0]
		dy := vertices[i][1] - vertices[0][1]
		if distance := dx*dx + dy*dy; distance > maxDistance {
			maxDistance = distance
			anchor = i
		}
	}

	firstPath := simplifyPath(vertices[:anchor+1], tolerance)
	secondInput := make([]position, 0, len(vertices)-anchor+1)
	secondInput = append(secondInput, vertices[anchor:]...)
	secondInput = append(secondInput, vertices[0])
	secondPath := simplifyPath(secondInput, tolerance)

	combined := make(linearRing, 0, len(firstPath)+len(secondPath)-1)
	combined = append(combined, firstPath...)
	combined = append(combined, secondPath[1:]...)
	combined = removeConsecutiveDuplicates(combined)
	if !positionsEqual(combined[0], combined[len(combined)-1]) {
		combined = append(combined, combined[0])
	} else {
		combined[len(combined)-1] = combined[0]
	}
	if len(combined) < 4 || !validRing(combined) {
		return normalized
	}
	return combined
}

func simplifyPath(points []position, tolerance float64) []position {
	if len(points) <= 2 {
		return append([]position(nil), points...)
	}
	keep := make([]bool, len(points))
	keep[0], keep[len(points)-1] = true, true
	type span struct{ start, end int }
	stack := []span{{start: 0, end: len(points) - 1}}
	toleranceSquared := tolerance * tolerance
	for len(stack) > 0 {
		current := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		farthest := -1
		maxDistance := toleranceSquared
		for i := current.start + 1; i < current.end; i++ {
			distance := pointSegmentDistanceSquared(points[i], points[current.start], points[current.end])
			if distance > maxDistance {
				maxDistance = distance
				farthest = i
			}
		}
		if farthest >= 0 {
			keep[farthest] = true
			stack = append(stack, span{start: current.start, end: farthest}, span{start: farthest, end: current.end})
		}
	}
	result := make([]position, 0, len(points))
	for i, point := range points {
		if keep[i] {
			result = append(result, point)
		}
	}
	return result
}

func pointSegmentDistanceSquared(point, start, end position) float64 {
	dx := end[0] - start[0]
	dy := end[1] - start[1]
	if dx == 0 && dy == 0 {
		dx = point[0] - start[0]
		dy = point[1] - start[1]
		return dx*dx + dy*dy
	}
	t := ((point[0]-start[0])*dx + (point[1]-start[1])*dy) / (dx*dx + dy*dy)
	t = math.Max(0, math.Min(1, t))
	nearestX := start[0] + t*dx
	nearestY := start[1] + t*dy
	dx = point[0] - nearestX
	dy = point[1] - nearestY
	return dx*dx + dy*dy
}

func normalizeRing(value linearRing) linearRing {
	result := removeConsecutiveDuplicates(append(linearRing(nil), value...))
	if len(result) > 0 {
		if !positionsEqual(result[0], result[len(result)-1]) {
			result = append(result, result[0])
		} else {
			result[len(result)-1] = result[0]
		}
	}
	return result
}

func removeConsecutiveDuplicates(value linearRing) linearRing {
	if len(value) < 2 {
		return value
	}
	result := make(linearRing, 0, len(value))
	for _, point := range value {
		if len(result) == 0 || !positionsEqual(result[len(result)-1], point) {
			result = append(result, point)
		}
	}
	return result
}

func positionsEqual(first, second position) bool {
	return len(first) >= 2 && len(second) >= 2 && first[0] == second[0] && first[1] == second[1]
}
