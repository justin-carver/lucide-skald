package icon

import "../parser"
import "core:math"

Vec2 :: parser.Vec2

// Absolute, curve-only path. Quads and arcs are converted to cubics, so
// every later stage deals with only 4 segment kinds.
//
// NOTE: This is assuming that Lucide in the future does not do anything
// weird and introduce new, icons that break this feature.
// CI should catch that, if so.
Segment_Kind :: enum u8 {
	Move,
	Line,
	Cubic,
	Close,
}

// Move/Line use p[0]; Cubic uses p[0], p[1] as control points and p[2] as the end.
Segment :: struct {
	kind: Segment_Kind,
	p:    [3]Vec2,
}

Path :: [dynamic]Segment

path_from_geometry :: proc(geometry: parser.Geometry) -> (path: Path) {
	switch g in geometry {
	case parser.Path_Shape:
		return path_from_commands(g.commands)
	case parser.Circle:
		append_ellipse(&path, g.center, {g.r, g.r})
	case parser.Ellipse:
		append_ellipse(&path, g.center, g.radii)
	case parser.Rect:
		append_rect(&path, g)
	case parser.Line:
		append(&path, Segment{kind = .Move, p = {g.a, {}, {}}})
		append(&path, Segment{kind = .Line, p = {g.b, {}, {}}})
	case parser.Poly:
		for point, i in g.points {
			append(&path, Segment{kind = i == 0 ? .Move : .Line, p = {point, {}, {}}})
		}
		if g.closed do append(&path, Segment{kind = .Close})
	}
	return path
}

path_from_commands :: proc(cmds: []parser.Path_Command) -> (path: Path) {
	cur, start, ctrl: Vec2
	prev: u8 // previous command, upper-cased
	need_move := false // after a close, resume drawing from the subpath start

	for cmd in cmds {
		relative := cmd.op >= 'a'
		op := relative ? cmd.op - ('a' - 'A') : cmd.op
		a := cmd.args
		origin := relative ? cur : Vec2{}

		switch op {
		case 'M':
			cur = Vec2{a[0], a[1]} + origin
			start = cur
			need_move = false
			append(&path, Segment{kind = .Move, p = {cur, {}, {}}})
		case 'Z':
			append(&path, Segment{kind = .Close})
			cur = start
			need_move = true
		case:
			if need_move {
				append(&path, Segment{kind = .Move, p = {start, {}, {}}})
				need_move = false
			}
			switch op {
			case 'L':
				cur = Vec2{a[0], a[1]} + origin
				append(&path, Segment{kind = .Line, p = {cur, {}, {}}})
			case 'H':
				cur.x = a[0] + origin.x
				append(&path, Segment{kind = .Line, p = {cur, {}, {}}})
			case 'V':
				cur.y = a[0] + origin.y
				append(&path, Segment{kind = .Line, p = {cur, {}, {}}})
			case 'C':
				ctrl = Vec2{a[2], a[3]} + origin
				end := Vec2{a[4], a[5]} + origin
				append(&path, Segment{kind = .Cubic, p = {Vec2{a[0], a[1]} + origin, ctrl, end}})
				cur = end
			case 'S':
				c1 := (prev == 'C' || prev == 'S') ? 2 * cur - ctrl : cur
				ctrl = Vec2{a[0], a[1]} + origin
				end := Vec2{a[2], a[3]} + origin
				append(&path, Segment{kind = .Cubic, p = {c1, ctrl, end}})
				cur = end
			case 'Q', 'T':
				if op == 'Q' {
					ctrl = Vec2{a[0], a[1]} + origin
				} else if prev != 'Q' && prev != 'T' {
					ctrl = cur
				} else {
					ctrl = 2 * cur - ctrl
				}
				end := op == 'Q' ? Vec2{a[2], a[3]} + origin : Vec2{a[0], a[1]} + origin
				append_quad(&path, cur, ctrl, end)
				cur = end
			case 'A':
				end := Vec2{a[5], a[6]} + origin
				append_arc(&path, cur, {a[0], a[1]}, a[2], a[3] != 0, a[4] != 0, end)
				cur = end
			}
		}
		prev = op
	}
	return path
}

// Exact degree elevation of a quadratic to a cubic.
append_quad :: proc(path: ^Path, from, ctrl, to: Vec2) {
	c1 := from + (2.0 / 3.0) * (ctrl - from)
	c2 := to + (2.0 / 3.0) * (ctrl - to)
	append(path, Segment{kind = .Cubic, p = {c1, c2, to}})
}

// SVG 1.1 appendix F.6: endpoint parameterization to center parameterization,
// then one cubic per quarter turn.
append_arc :: proc(
	path: ^Path,
	from, radii: Vec2,
	x_axis_rotation: f64,
	large_arc, sweep: bool,
	to: Vec2,
) {
	if from == to do return

	rx, ry := abs(radii.x), abs(radii.y)
	if rx == 0 || ry == 0 {
		append(path, Segment{kind = .Line, p = {to, {}, {}}})
		return
	}

	sin_phi, cos_phi := math.sincos(math.to_radians(x_axis_rotation))
	half := (from - to) / 2
	x1 := cos_phi * half.x + sin_phi * half.y
	y1 := -sin_phi * half.x + cos_phi * half.y

	// Radii too small to span the endpoints are scaled up until they just fit.
	lambda := x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
	if lambda > 1 {
		scale := math.sqrt(lambda)
		rx *= scale
		ry *= scale
	}

	rx2, ry2 := rx * rx, ry * ry
	numerator := rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1
	denominator := rx2 * y1 * y1 + ry2 * x1 * x1
	coefficient := math.sqrt(max(0, numerator / denominator))
	if large_arc == sweep do coefficient = -coefficient

	cx := coefficient * rx * y1 / ry
	cy := -coefficient * ry * x1 / rx
	center := Vec2{cos_phi * cx - sin_phi * cy, sin_phi * cx + cos_phi * cy} + (from + to) / 2

	u := Vec2{(x1 - cx) / rx, (y1 - cy) / ry}
	v := Vec2{(-x1 - cx) / rx, (-y1 - cy) / ry}
	theta := math.atan2(u.y, u.x)
	delta := math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
	if !sweep && delta > 0 {
		delta -= math.TAU
	} else if sweep && delta < 0 {
		delta += math.TAU
	}

	count := max(1, int(math.ceil(abs(delta) / (math.PI / 2) - 1e-9)))
	step := delta / f64(count)
	k := 4.0 / 3.0 * math.tan(step / 4)

	to_user :: proc(center, radii: Vec2, sin_phi, cos_phi: f64, unit: Vec2) -> Vec2 {
		return {
			center.x + cos_phi * radii.x * unit.x - sin_phi * radii.y * unit.y,
			center.y + sin_phi * radii.x * unit.x + cos_phi * radii.y * unit.y,
		}
	}

	fitted := Vec2{rx, ry}
	for i in 0 ..< count {
		sin_a, cos_a := math.sincos(theta + f64(i) * step)
		sin_b, cos_b := math.sincos(theta + f64(i + 1) * step)

		// Unit-circle control points: end point plus/minus k times the tangent.
		c1 := to_user(center, fitted, sin_phi, cos_phi, {cos_a - k * sin_a, sin_a + k * cos_a})
		c2 := to_user(center, fitted, sin_phi, cos_phi, {cos_b + k * sin_b, sin_b - k * cos_b})
		end := i == count - 1 ? to : to_user(center, fitted, sin_phi, cos_phi, {cos_b, sin_b})
		append(path, Segment{kind = .Cubic, p = {c1, c2, end}})
	}
}

@(private)
append_ellipse :: proc(path: ^Path, center, radii: Vec2) {
	right := center + Vec2{radii.x, 0}
	left := center - Vec2{radii.x, 0}
	append(path, Segment{kind = .Move, p = {right, {}, {}}})
	append_arc(path, right, radii, 0, false, true, left)
	append_arc(path, left, radii, 0, false, true, right)
	append(path, Segment{kind = .Close})
}

@(private)
append_rect :: proc(path: ^Path, r: parser.Rect) {
	x0, y0 := r.origin.x, r.origin.y
	x1, y1 := x0 + r.size.x, y0 + r.size.y
	rx, ry := r.radii.x, r.radii.y

	line :: proc(path: ^Path, x, y: f64) {
		append(path, Segment{kind = .Line, p = {{x, y}, {}, {}}})
	}

	if rx <= 0 || ry <= 0 {
		append(path, Segment{kind = .Move, p = {{x0, y0}, {}, {}}})
		line(path, x1, y0)
		line(path, x1, y1)
		line(path, x0, y1)
	} else {
		radii := Vec2{rx, ry}
		append(path, Segment{kind = .Move, p = {{x0 + rx, y0}, {}, {}}})
		line(path, x1 - rx, y0)
		append_arc(path, {x1 - rx, y0}, radii, 0, false, true, {x1, y0 + ry})
		line(path, x1, y1 - ry)
		append_arc(path, {x1, y1 - ry}, radii, 0, false, true, {x1 - rx, y1})
		line(path, x0 + rx, y1)
		append_arc(path, {x0 + rx, y1}, radii, 0, false, true, {x0, y1 - ry})
		line(path, x0, y0 + ry)
		append_arc(path, {x0, y0 + ry}, radii, 0, false, true, {x0 + rx, y0})
	}
	append(path, Segment{kind = .Close})
}
