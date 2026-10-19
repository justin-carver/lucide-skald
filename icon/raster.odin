package icon

import "../parser"
import "core:math"
import "core:slice"

SUBSAMPLES :: 16

// y0 < y1 always; `dir` records which way the original segment ran so the
// winding number survives the normalization.
Edge :: struct {
	x0, y0, y1: f64,
	dxdy:       f64,
	dir:        i32,
}

@(private)
Crossing :: struct {
	x:   f64,
	dir: i32,
}

edge_push :: proc(edges: ^[dynamic]Edge, a, b: Vec2) {
	if a.y == b.y do return
	if a.y < b.y {
		append(
			edges,
			Edge{x0 = a.x, y0 = a.y, y1 = b.y, dxdy = (b.x - a.x) / (b.y - a.y), dir = 1},
		)
	} else {
		append(
			edges,
			Edge{x0 = b.x, y0 = b.y, y1 = a.y, dxdy = (a.x - b.x) / (a.y - b.y), dir = -1},
		)
	}
}

// Closes the ring implicitly, as filling always does.
polygon_edges :: proc(edges: ^[dynamic]Edge, pts: []Vec2) {
	for i in 0 ..< len(pts) {
		edge_push(edges, pts[i], pts[(i + 1) % len(pts)])
	}
}

// Same as polygon_edges but forces counter-clockwise winding, so
// overlapping polys always sums to a union under the non-zero rule.
emit_polygon :: proc(edges: ^[dynamic]Edge, pts: []Vec2) {
	if len(pts) < 3 do return

	twice_area := 0.0
	for i in 0 ..< len(pts) {
		a, b := pts[i], pts[(i + 1) % len(pts)]
		twice_area += a.x * b.y - b.x * a.y
	}
	flip := twice_area < 0
	for i in 0 ..< len(pts) {
		a, b := pts[i], pts[(i + 1) % len(pts)]
		if flip do a, b = b, a
		edge_push(edges, a, b)
	}
}

// Writes per-pixel coverage in [0, 1] for the area `edges` encloses.
// Reorders `edges`.
fill_coverage :: proc(edges: []Edge, rule: parser.Fill_Rule, width, height: int, coverage: []f32) {
	slice.zero(coverage)
	if len(edges) == 0 do return

	slice.sort_by(edges, proc(a, b: Edge) -> bool {return a.y0 < b.y0})

	top, bottom := edges[0].y0, edges[0].y1
	for e in edges do bottom = max(bottom, e.y1)
	first_row := max(0, int(math.floor(top)))
	last_row := min(height, int(math.ceil(bottom)))

	active := make([dynamic]int, 0, 32)
	crossings := make([dynamic]Crossing, 0, 32)
	next := 0
	weight := f32(1.0 / SUBSAMPLES)

	for y in first_row ..< last_row {
		row := coverage[y * width:(y + 1) * width]
		for sub in 0 ..< SUBSAMPLES {
			sample_y := f64(y) + (f64(sub) + 0.5) / SUBSAMPLES

			for next < len(edges) && edges[next].y0 <= sample_y {
				append(&active, next)
				next += 1
			}

			clear(&crossings)
			kept := 0
			for index in active {
				e := edges[index]
				if e.y1 <= sample_y do continue
				active[kept] = index
				kept += 1
				append(&crossings, Crossing{x = e.x0 + (sample_y - e.y0) * e.dxdy, dir = e.dir})
			}
			resize(&active, kept)

			// Insertion sort: crossings are nearly ordered and rarely numerous.
			for i in 1 ..< len(crossings) {
				c := crossings[i]
				j := i
				for j > 0 && crossings[j - 1].x > c.x {
					crossings[j] = crossings[j - 1]
					j -= 1
				}
				crossings[j] = c
			}

			winding := 0
			span_start := 0.0
			for c in crossings {
				was_inside := is_inside(winding, rule)
				winding += int(c.dir)
				now_inside := is_inside(winding, rule)
				if !was_inside && now_inside {
					span_start = c.x
				} else if was_inside && !now_inside {
					add_span(row, span_start, c.x, weight)
				}
			}
		}
	}
}

@(private)
is_inside :: proc(winding: int, rule: parser.Fill_Rule) -> bool {
	return rule == .Non_Zero ? winding != 0 : winding & 1 != 0
}

// Adds `weight` per pixel of horizontal overlap with [x0, x1), clipped to the row.
@(private)
add_span :: proc(row: []f32, x0, x1: f64, weight: f32) {
	limit := f64(len(row))
	a, b := clamp(x0, 0, limit), clamp(x1, 0, limit)
	if b <= a do return

	first, last := int(a), int(b)
	if first == last {
		row[first] += f32(b - a) * weight
		return
	}
	row[first] += f32(f64(first + 1) - a) * weight
	for i in first + 1 ..< last do row[i] += weight
	if last < len(row) do row[last] += f32(b - f64(last)) * weight
}

// Source-over onto a premultiplied canvas. `color` is straight RGBA.
composite :: proc(canvas: [][4]f32, coverage: []f32, color: [4]f32) {
	for cov, i in coverage {
		if cov <= 0 do continue
		alpha := min(cov, 1) * color.a
		px := &canvas[i]
		inverse := 1 - alpha
		px^ = {
			color.r * alpha + px.r * inverse,
			color.g * alpha + px.g * inverse,
			color.b * alpha + px.b * inverse,
			alpha + px.a * inverse,
		}
	}
}
