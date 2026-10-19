package icon

import "../parser"
import "core:math"

Stroke_Params :: struct {
	half_width:  f64,
	cap:         parser.Line_Cap,
	join:        parser.Line_Join,
	miter_limit: f64,
}

// The stroke outline is built as a union of convex pieces (a quad per segment,
// a wedge per join, a fan per cap) that all wind the same way. Filling the pile
// with the non-zero rule merges them, so self-overlap and tight inner joins
// need no special handling.
@(private)
Stroker :: struct {
	params:   Stroke_Params,
	arc_step: f64,
	edges:    ^[dynamic]Edge,
	scratch:  [dynamic]Vec2,
}

stroke_subpaths :: proc(subpaths: []Subpath, params: Stroke_Params, edges: ^[dynamic]Edge) {
	hw := params.half_width
	s := Stroker {
		params   = params,
		edges    = edges,
		// Largest angle whose chord stays within tolerance of the circle.
		arc_step = hw > FLATTEN_TOLERANCE ? 2 * math.acos(1 - FLATTEN_TOLERANCE / hw) : math.PI / 2,
		scratch  = make([dynamic]Vec2, 0, 64),
	}
	for sp in subpaths do stroke_subpath(&s, sp)
}

@(private)
stroke_subpath :: proc(s: ^Stroker, sp: Subpath) {
	pts := sp.points[:]
	n := len(pts)
	if n == 0 do return
	if n == 1 {
		stroke_dot(s, pts[0])
		return
	}

	hw := s.params.half_width
	segments := sp.closed ? n : n - 1

	for i in 0 ..< segments {
		a, b := pts[i], pts[(i + 1) % n]
		normal := left_normal(direction(a, b)) * hw
		emit_polygon(s.edges, {a + normal, b + normal, b - normal, a - normal})
	}

	join_first, join_last := sp.closed ? 0 : 1, sp.closed ? n - 1 : n - 2
	for j in join_first ..= join_last {
		before := pts[(j - 1 + n) % n]
		after := pts[(j + 1) % n]
		emit_join(s, pts[j], direction(before, pts[j]), direction(pts[j], after))
	}

	if !sp.closed {
		emit_cap(s, pts[0], -direction(pts[0], pts[1]))
		emit_cap(s, pts[n - 1], direction(pts[n - 2], pts[n - 1]))
	}
}

@(private)
emit_join :: proc(s: ^Stroker, v, d0, d1: Vec2) {
	hw := s.params.half_width
	cross := d0.x * d1.y - d0.y * d1.x
	dot := d0.x * d1.x + d0.y * d1.y

	// Straight through, or doubling back on itself.
	if abs(cross) < 1e-9 {
		if dot < 0 && s.params.join == .Round do emit_cap_round(s, v, d0)
		return
	}

	// Offsets on the outside of the turn; the inside is covered by the segment quads.
	side := cross > 0 ? -hw : hw
	o0 := left_normal(d0) * side
	o1 := left_normal(d1) * side

	switch s.params.join {
	case .Round:
		emit_fan(s, v, o0, math.atan2(o0.x * o1.y - o0.y * o1.x, o0.x * o1.x + o0.y * o1.y))
	case .Bevel:
		emit_polygon(s.edges, {v, v + o0, v + o1})
	case .Miter:
		// miter length / stroke width = 1 / cos(turn / 2)
		ratio := 1 / math.sqrt((1 + dot) / 2)
		if ratio <= s.params.miter_limit {
			emit_polygon(s.edges, {v, v + o0, v + (o0 + o1) / (1 + dot), v + o1})
		} else {
			emit_polygon(s.edges, {v, v + o0, v + o1})
		}
	}
}

// `outward` points away from the line.
@(private)
emit_cap :: proc(s: ^Stroker, p, outward: Vec2) {
	hw := s.params.half_width
	switch s.params.cap {
	case .Butt:
	case .Square:
		normal := left_normal(outward) * hw
		reach := outward * hw
		emit_polygon(s.edges, {p + normal, p + normal + reach, p - normal + reach, p - normal})
	case .Round:
		emit_cap_round(s, p, outward)
	}
}

@(private)
emit_cap_round :: proc(s: ^Stroker, p, outward: Vec2) {
	emit_fan(s, p, left_normal(outward) * s.params.half_width, -math.PI)
}

// Zero-length subpath: round caps still paint a dot, square caps a square.
@(private)
stroke_dot :: proc(s: ^Stroker, p: Vec2) {
	hw := s.params.half_width
	switch s.params.cap {
	case .Butt:
	case .Square:
		emit_polygon(
			s.edges,
			{p + Vec2{-hw, -hw}, p + Vec2{hw, -hw}, p + Vec2{hw, hw}, p + Vec2{-hw, hw}},
		)
	case .Round:
		count := max(8, int(math.ceil(math.TAU / s.arc_step)))
		clear(&s.scratch)
		for i in 0 ..< count {
			sin_a, cos_a := math.sincos(math.TAU * f64(i) / f64(count))
			append(&s.scratch, p + Vec2{cos_a, sin_a} * hw)
		}
		emit_polygon(s.edges, s.scratch[:])
	}
}

// Pie slice around `center`, starting at offset `from` and turning by `sweep`.
@(private)
emit_fan :: proc(s: ^Stroker, center, from: Vec2, sweep: f64) {
	count := max(1, int(math.ceil(abs(sweep) / s.arc_step)))
	clear(&s.scratch)
	append(&s.scratch, center)
	for i in 0 ..= count {
		sin_a, cos_a := math.sincos(sweep * f64(i) / f64(count))
		append(
			&s.scratch,
			center + Vec2{from.x * cos_a - from.y * sin_a, from.x * sin_a + from.y * cos_a},
		)
	}
	emit_polygon(s.edges, s.scratch[:])
}

@(private)
direction :: proc(a, b: Vec2) -> Vec2 {
	d := b - a
	return d / math.sqrt(d.x * d.x + d.y * d.y)
}

@(private)
left_normal :: proc(d: Vec2) -> Vec2 {
	return {-d.y, d.x}
}
