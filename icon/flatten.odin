package icon

import "core:math"

// Maximum distance, in output pixels, between a curve and its polyline.
FLATTEN_TOLERANCE :: 0.02

// SVG user space to output pixels. Uniform scale only, which is all that
// viewBox fitting needs and keeps stroke widths a simple multiply.
Transform :: struct {
	scale:  f64,
	offset: Vec2,
}

transform_point :: proc(t: Transform, p: Vec2) -> Vec2 {
	return p * t.scale + t.offset
}

Subpath :: struct {
	points: [dynamic]Vec2,
	closed: bool,
}

@(private)
Flattener :: struct {
	subpaths:  [dynamic]Subpath,
	current:   Subpath,
	active:    bool,
	drawn:     bool, // a lone Move draws nothing, not even a round cap
	transform: Transform,
}

flatten_path :: proc(path: Path, transform: Transform) -> [dynamic]Subpath {
	f := Flattener {
		transform = transform,
	}
	cur: Vec2
	for seg in path {
		switch seg.kind {
		case .Move:
			flattener_finish(&f)
			cur = transform_point(transform, seg.p[0])
			f.active = true
			f.current = Subpath{}
			append(&f.current.points, cur)
		case .Line:
			cur = transform_point(transform, seg.p[0])
			flattener_push(&f, cur)
			f.drawn = true
		case .Cubic:
			c1 := transform_point(transform, seg.p[0])
			c2 := transform_point(transform, seg.p[1])
			end := transform_point(transform, seg.p[2])
			flatten_cubic(&f, cur, c1, c2, end)
			cur = end
			f.drawn = true
		case .Close:
			f.current.closed = true
			f.drawn = true
			flattener_finish(&f)
		}
	}
	flattener_finish(&f)
	return f.subpaths
}

@(private)
flattener_push :: proc(f: ^Flattener, p: Vec2) {
	pts := &f.current.points
	if len(pts) > 0 && pts[len(pts) - 1] == p do return
	append(pts, p)
}

@(private)
flattener_finish :: proc(f: ^Flattener) {
	defer {
		f.active = false
		f.drawn = false
		f.current = Subpath{}
	}
	if !f.active || !f.drawn do return

	pts := &f.current.points
	if f.current.closed && len(pts) > 1 && pts[0] == pts[len(pts) - 1] {
		pop(pts)
	}
	append(&f.subpaths, f.current)
}

// Uniform parameter steps, with the step count taken from the control polygon's
// second differences (Wang's formula): the chord error is bounded by
// tolerance without any recursion.
@(private)
flatten_cubic :: proc(f: ^Flattener, p0, p1, p2, p3: Vec2) {
	second_a := p0 - 2 * p1 + p2
	second_b := p1 - 2 * p2 + p3
	m := max(math.sqrt(second_a.x * second_a.x + second_a.y * second_a.y), math.sqrt(second_b.x * second_b.x + second_b.y * second_b.y))
	count := max(1, int(math.ceil(math.sqrt(0.75 * m / FLATTEN_TOLERANCE))))

	for i in 1 ..< count {
		t := f64(i) / f64(count)
		mt := 1 - t
		p := mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3
		flattener_push(f, p)
	}
	flattener_push(f, p3)
}
