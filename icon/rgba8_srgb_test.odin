package icon

import "../parser"
import "core:bytes"
import "core:encoding/xml"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

TESTDATA :: #directory + "testdata"

// Goldens are resvg's own 24px renders. Both renderers anti-alias slightly
// differently (resvg is the less exact one), so the check is loose enough to
// ignore that and tight enough to catch wrong geometry.
GOLDEN_MEAN_TOLERANCE :: 4.0
GOLDEN_WORST_TOLERANCE :: 110

STROKED :: `fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"`

svg_source :: proc(body: string, view_box := "0 0 24 24") -> string {
	return fmt.tprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s">%s</svg>`,
		view_box,
		body,
	)
}

render_inline :: proc(
	source: string,
	size := 0,
	color := BLACK,
) -> (
	img: Image_Buffer,
	err: Conversion_Error,
) {
	doc, xml_err := xml.parse(source, allocator = context.temp_allocator)
	if xml_err != .None do return {}, .Invalid_XML
	return rasterize_document(doc, size, color)
}

fixture_paths :: proc() -> []string {
	infos, _ := os.read_all_directory_by_path(TESTDATA, context.temp_allocator)
	paths := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if strings.has_suffix(info.name, ".svg") do append(&paths, info.fullpath)
	}
	return paths[:]
}

coverage_sum :: proc(img: Image_Buffer) -> f64 {
	sum := 0.0
	for p in img.pixels do sum += f64(p.a)
	return sum / 255
}

alpha_at :: proc(img: Image_Buffer, x, y: int) -> int {
	return int(img.pixels[y * img.width + x].a)
}

// According to the Skald repo (@Skald/skald/image.odin#L424-427):
//
// `rgba` must be exactly `w * h * 4` bytes. Format is RGBA8 sRGB,
// matching the file-loaded path; pre-multiplied alpha is not assumed.
// The bytes are copied into a staging buffer synchronously — the
// caller's slice does not need to outlive this call.

@(test)
fixtures_produce_w_h_4_bytes :: proc(t: ^testing.T) {
	paths := fixture_paths()
	testing.expect(t, len(paths) > 0, "no fixtures found")

	for path in paths {
		for size in ([?]int{0, 17, 24, 48}) {
			img, err := rasterize_svg(path, size)
			defer image_destroy(&img)
			if !testing.expectf(t, err == .None, "%s @%d: %v", path, size, err) do continue

			want := size == 0 ? 24 : size
			testing.expectf(
				t,
				img.width == want && img.height == want,
				"%s @%d: got %dx%d",
				path,
				size,
				img.width,
				img.height,
			)
			testing.expectf(
				t,
				len(image_bytes(img)) == img.width * img.height * 4,
				"%s @%d: %d bytes for %dx%d",
				path,
				size,
				len(image_bytes(img)),
				img.width,
				img.height,
			)
		}
	}
}

@(test)
svg_to_rgba8_returns_raw_bytes :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/house.svg", TESTDATA)
	bytes_out, width, height, err := svg_to_rgba8(path, 32)
	defer delete(bytes_out)

	testing.expect_value(t, err, Conversion_Error.None)
	testing.expect_value(t, width, 32)
	testing.expect_value(t, height, 32)
	testing.expect_value(t, len(bytes_out), 32 * 32 * 4)

	// Alpha is the 4th byte of each pixel, so some of them must be non-zero.
	painted := false
	for i := 3; i < len(bytes_out); i += 4 {
		if bytes_out[i] != 0 do painted = true
	}
	testing.expect(t, painted)
}

@(test)
output_dimensions_follow_aspect_ratio :: proc(t: ^testing.T) {
	cases := [?]struct {
		view_box: string,
		size:     int,
		w, h:     int,
	} {
		{"0 0 30 10", 60, 60, 20},
		{"0 0 30 10", 0, 30, 10},
		{"0 0 10 30", 5, 5, 15},
		{"0 0 24 24", 1, 1, 1},
	}

	for c in cases {
		img, err := render_inline(svg_source(`<path d="M0 0h1"/>`, c.view_box), c.size)
		defer image_destroy(&img)
		testing.expect_value(t, err, Conversion_Error.None)
		testing.expectf(
			t,
			img.width == c.w && img.height == c.h,
			"%s @%d: got %dx%d",
			c.view_box,
			c.size,
			img.width,
			img.height,
		)
		testing.expect_value(t, len(image_bytes(img)), c.w * c.h * 4)
	}
}

@(test)
fixtures_draw_something :: proc(t: ^testing.T) {
	for path in fixture_paths() {
		img, err := rasterize_svg(path)
		defer image_destroy(&img)
		if !testing.expectf(t, err == .None, "%s: %v", path, err) do continue

		opaque, transparent := 0, 0
		for p in img.pixels {
			if p.a == 255 do opaque += 1
			if p.a == 0 do transparent += 1
			// Black tint: any colour channel at all would mean a bad un-premultiply.
			if p.a != 0 && (p.r != 0 || p.g != 0 || p.b != 0) {
				testing.expectf(t, false, "%s: coloured pixel %v", path, p)
				break
			}
		}
		testing.expectf(t, opaque > 0, "%s: nothing opaque", path)
		testing.expectf(t, transparent > 0, "%s: nothing transparent", path)
	}
}

@(test)
rendering_is_deterministic :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/paper-bag.svg", TESTDATA)
	a, err_a := rasterize_svg(path, 40)
	defer image_destroy(&a)
	b, err_b := rasterize_svg(path, 40)
	defer image_destroy(&b)

	testing.expect_value(t, err_a, Conversion_Error.None)
	testing.expect_value(t, err_b, Conversion_Error.None)
	testing.expect(t, bytes.equal(image_bytes(a), image_bytes(b)))
}

@(test)
fixtures_match_goldens :: proc(t: ^testing.T) {
	for path in fixture_paths() {
		name := filepath.stem(filepath.base(path))
		golden, png_err := png.load_from_file(
			fmt.tprintf("%s/golden/%s.png", TESTDATA, name),
			{.alpha_add_if_missing},
		)
		defer png.destroy(golden)
		if !testing.expectf(t, png_err == nil, "%s: golden failed to load: %v", name, png_err) do continue

		img, err := rasterize_svg(path)
		defer image_destroy(&img)
		if !testing.expectf(t, err == .None, "%s: %v", name, err) do continue
		if !testing.expectf(t, golden.width == img.width && golden.height == img.height && golden.channels == 4, "%s: golden is %dx%dx%d", name, golden.width, golden.height, golden.channels) do continue

		expected := bytes.buffer_to_bytes(&golden.pixels)
		sum, worst := 0, 0
		for p, i in img.pixels {
			diff := abs(int(p.a) - int(expected[i * 4 + 3]))
			sum += diff
			worst = max(worst, diff)
		}
		mean := f64(sum) / f64(len(img.pixels))
		log.infof("%-16s mean %.2f  worst %d", name, mean, worst)
		testing.expectf(t, mean <= GOLDEN_MEAN_TOLERANCE, "%s: mean alpha error %.2f", name, mean)
		testing.expectf(
			t,
			worst <= GOLDEN_WORST_TOLERANCE,
			"%s: worst alpha error %d",
			name,
			worst,
		)
	}
}

// Set LUCIDE_ICONS_DIR to the upstream `icons/` directory to run every icon through.
//   `LUCIDE_ICONS_DIR=~/github/forks/lucide/icons odin test icon`
@(test)
sweep_upstream_icons :: proc(t: ^testing.T) {
	dir, found := os.lookup_env("LUCIDE_ICONS_DIR", context.temp_allocator)
	if !found || dir == "" {
		log.info("LUCIDE_ICONS_DIR not set, skipping sweep")
		return
	}
	infos, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if !testing.expectf(t, read_err == nil, "cannot read %s: %v", dir, read_err) do return

	count := 0
	for info in infos {
		if !strings.has_suffix(info.name, ".svg") do continue
		count += 1

		for size in ([?]int{0, 48}) {
			img, err := rasterize_svg(info.fullpath, size)
			if !testing.expectf(t, err == .None, "%s @%d: %v", info.name, size, err) do continue

			want := size == 0 ? 24 : size
			testing.expectf(
				t,
				img.width == want && img.height == want,
				"%s @%d: got %dx%d",
				info.name,
				size,
				img.width,
				img.height,
			)
			testing.expectf(
				t,
				len(image_bytes(img)) == img.width * img.height * 4,
				"%s @%d: wrong byte count",
				info.name,
				size,
			)
			testing.expectf(t, coverage_sum(img) > 0, "%s @%d: blank image", info.name, size)
			image_destroy(&img)
		}
	}
	log.infof("swept %d icons", count)
	testing.expect(t, count > 0)
}

// ---------------------------------------------------------------------------
// Accuracy against shapes whose area is known exactly.
// ---------------------------------------------------------------------------

@(test)
coverage_matches_analytic_areas :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:     string,
		body:     string,
		expected: f64,
	} {
		{
			"stroked circle",
			`<circle cx="12" cy="12" r="10" ` + STROKED + `/>`,
			math.PI * (121 - 81),
		},
		{"filled circle", `<circle cx="12" cy="12" r="9" fill="currentColor"/>`, math.PI * 81},
		{
			"filled ellipse",
			`<ellipse cx="12" cy="12" rx="10" ry="6" fill="currentColor"/>`,
			math.PI * 60,
		},
		{
			"rounded rect",
			`<rect x="4" y="4" width="16" height="16" rx="4" fill="currentColor"/>`,
			256 - 4 * 16 * (1 - math.PI / 4),
		},
		{
			"semicircle via arc",
			`<path d="M4 12a8 8 0 0 1 16 0z" fill="currentColor"/>`,
			math.PI * 64 / 2,
		},
		{"large arc", `<path d="M4 12A8 8 0 1 1 20 12z" fill="currentColor"/>`, math.PI * 64 / 2},
		{"quadratic", `<path d="M4 20Q12 -4 20 20z" fill="currentColor"/>`, 128},
		{
			"round join rect",
			`<rect x="4" y="4" width="16" height="16" ` + STROKED + `/>`,
			18 * 18 - 4 * (1 - math.PI / 4) - 14 * 14,
		},
		{
			"miter join rect",
			`<rect x="4" y="4" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"/>`,
			18 * 18 - 14 * 14,
		},
		{
			"bevel join rect",
			`<rect x="4" y="4" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="bevel"/>`,
			18 * 18 - 14 * 14 - 4 * 0.5,
		},
		{
			"butt caps",
			`<path d="M4 12h16" fill="none" stroke="currentColor" stroke-width="2"/>`,
			32,
		},
		{
			"square caps",
			`<path d="M4 12h16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="square"/>`,
			36,
		},
		{"round caps", `<path d="M4 12h16" ` + STROKED + `/>`, 32 + math.PI},
		{"zero-length round dot", `<path d="M12 12h0" ` + STROKED + `/>`, math.PI},
		{
			"zero-length square dot",
			`<path d="M12 12h0" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="square"/>`,
			4,
		},
		{
			"zero-length butt dot",
			`<path d="M12 12h0" fill="none" stroke="currentColor" stroke-width="2"/>`,
			0,
		},
		{
			"thick circle swallowing its centre",
			`<circle cx="12" cy="12" r="1" fill="none" stroke="currentColor" stroke-width="6"/>`,
			math.PI * 16,
		},
	}

	// Scaling the output must scale stroke widths and curves with it.
	for size in ([?]int{24, 48, 100}) {
		scale := f64(size * size) / (24 * 24)
		for c in cases {
			img, err := render_inline(svg_source(c.body), size)
			defer image_destroy(&img)
			if !testing.expectf(t, err == .None, "%s @%d: %v", c.name, size, err) do continue

			// Horizontal edges are quantized to 1/16 px by the vertical sampling,
			// so the allowed error grows with edge length.
			got, expected := coverage_sum(img), c.expected * scale
			tolerance := max(0.5, 0.006 * expected)
			testing.expectf(
				t,
				abs(got - expected) <= tolerance,
				"%s @%d: area %.3f, expected %.3f",
				c.name,
				size,
				got,
				expected,
			)
		}
	}
}

@(test)
fill_coverage_is_exact_on_pixel_fractions :: proc(t: ^testing.T) {
	img, err := render_inline(
		svg_source(
			`<rect x="1.25" y="2.5" width="3.5" height="2" fill="currentColor"/>`,
			"0 0 8 8",
		),
	)
	defer image_destroy(&img)
	testing.expect_value(t, err, Conversion_Error.None)
	testing.expect_value(t, img.width, 8)

	// Columns 1 and 4 are 75% covered, rows 2 and 4 are 50% covered.
	testing.expect_value(t, alpha_at(img, 2, 3), 255)
	testing.expect_value(t, alpha_at(img, 1, 3), 191) // 0.75
	testing.expect_value(t, alpha_at(img, 4, 3), 191)
	testing.expect_value(t, alpha_at(img, 2, 2), 128) // 0.5
	testing.expect_value(t, alpha_at(img, 2, 4), 128)
	testing.expect_value(t, alpha_at(img, 1, 2), 96) // 0.375
	testing.expect_value(t, alpha_at(img, 0, 3), 0)
	testing.expect_value(t, alpha_at(img, 5, 3), 0)
	testing.expect_value(t, alpha_at(img, 2, 5), 0)
}

@(test)
fill_rules_differ_on_nested_same_direction_squares :: proc(t: ^testing.T) {
	ring := `d="M1 1h6v6h-6z M2 2h4v4h-4z"`
	for rule in ([?]struct {
			rule: string,
			hole: int,
		}{{"nonzero", 255}, {"evenodd", 0}}) {
		img, err := render_inline(
			svg_source(
				fmt.tprintf(`<path %s fill="currentColor" fill-rule="%s"/>`, ring, rule.rule),
				"0 0 8 8",
			),
		)
		defer image_destroy(&img)
		testing.expect_value(t, err, Conversion_Error.None)
		testing.expectf(
			t,
			alpha_at(img, 4, 4) == rule.hole,
			"%s: centre alpha %d",
			rule.rule,
			alpha_at(img, 4, 4),
		)
		testing.expect_value(t, alpha_at(img, 1, 1), 255)
	}
}

@(test)
miter_limit_falls_back_to_bevel :: proc(t: ^testing.T) {
	// A narrow spike: the miter would be 1/sin(~7 deg) = ~8x the width.
	spike :: `d="M2 20L12 2L22 20" fill="none" stroke="currentColor" stroke-width="2"`
	miter, e0 := render_inline(svg_source(fmt.tprintf(`<path %s stroke-miterlimit="20"/>`, spike)))
	defer image_destroy(&miter)
	limited, e1 := render_inline(
		svg_source(fmt.tprintf(`<path %s stroke-miterlimit="2"/>`, spike)),
	)
	defer image_destroy(&limited)
	bevel, e2 := render_inline(
		svg_source(fmt.tprintf(`<path %s stroke-linejoin="bevel"/>`, spike)),
	)
	defer image_destroy(&bevel)

	testing.expect_value(t, e0, Conversion_Error.None)
	testing.expect_value(t, e1, Conversion_Error.None)
	testing.expect_value(t, e2, Conversion_Error.None)
	testing.expect(
		t,
		coverage_sum(miter) > coverage_sum(limited) + 1,
		"a long miter adds visible area",
	)
	testing.expectf(
		t,
		abs(coverage_sum(limited) - coverage_sum(bevel)) < 1e-6,
		"limit 2 should equal bevel: %v vs %v",
		coverage_sum(limited),
		coverage_sum(bevel),
	)
}

@(test)
stroke_matches_brute_force_distance_oracle :: proc(t: ^testing.T) {
	// With round caps and joins the stroke is exactly the set of points within
	// half the width of the path, which a brute-force sampler can check directly.
	// The zigzag and the star pile many overlapping, opposite-turning pieces on
	// top of each other, which is where a winding mistake would punch holes.
	cases := [?]struct {
		name:   string,
		d:      string,
		width:  f64,
		closed: bool,
		pts:    []Vec2,
	} {
		{"polyline", "M3 20L9 4L15 16L21 5", 3, false, {{3, 20}, {9, 4}, {15, 16}, {21, 5}}},
		{
			"zigzag",
			"M3 6L8 7L3 8L8 9L3 10L8 11L3 12",
			3,
			false,
			{{3, 6}, {8, 7}, {3, 8}, {8, 9}, {3, 10}, {8, 11}, {3, 12}},
		},
		{
			"tight zigzag",
			"M5 5L7 6L5 7L7 8L5 9L7 10L5 11L7 12L5 13",
			4,
			false,
			{{5, 5}, {7, 6}, {5, 7}, {7, 8}, {5, 9}, {7, 10}, {5, 11}, {7, 12}, {5, 13}},
		},
		{
			"star",
			"M12 2L19 22L3 8L21 8L5 22z",
			2.5,
			true,
			{{12, 2}, {19, 22}, {3, 8}, {21, 8}, {5, 22}},
		},
	}

	distance_to_segment :: proc(p, a, b: Vec2) -> f64 {
		ab := b - a
		u := clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y), 0, 1)
		d := p - (a + ab * u)
		return math.sqrt(d.x * d.x + d.y * d.y)
	}

	SAMPLES :: 8
	for c in cases {
		body := fmt.tprintf(
			`<path d="%s" fill="none" stroke="currentColor" stroke-width="%v" stroke-linecap="round" stroke-linejoin="round"/>`,
			c.d,
			c.width,
		)
		img, err := render_inline(svg_source(body))
		defer image_destroy(&img)
		if !testing.expectf(t, err == .None, "%s: %v", c.name, err) do continue

		segments := len(c.pts) - (c.closed ? 0 : 1)
		worst, total := 0.0, 0.0
		for y in 0 ..< img.height {
			for x in 0 ..< img.width {
				inside := 0
				for sy in 0 ..< SAMPLES {
					for sx in 0 ..< SAMPLES {
						p := Vec2 {
							f64(x) + (f64(sx) + 0.5) / SAMPLES,
							f64(y) + (f64(sy) + 0.5) / SAMPLES,
						}
						for i in 0 ..< segments {
							if distance_to_segment(p, c.pts[i], c.pts[(i + 1) % len(c.pts)]) <=
							   c.width / 2 {
								inside += 1
								break
							}
						}
					}
				}
				diff := abs(f64(alpha_at(img, x, y)) - f64(inside) / (SAMPLES * SAMPLES) * 255)
				worst = max(worst, diff)
				total += diff
			}
		}
		mean := total / f64(len(img.pixels))
		log.infof("oracle %-12s mean %.2f  worst %.1f", c.name, mean, worst)
		testing.expectf(t, mean < 1.0, "%s: mean error %.2f", c.name, mean)
		testing.expectf(t, worst < 10, "%s: worst error %.1f", c.name, worst)
	}
}

// ---------------------------------------------------------------------------
// Colour, alpha, and transforms.
// ---------------------------------------------------------------------------

@(test)
color_uses_straight_alpha :: proc(t: ^testing.T) {
	img, err := render_inline(
		svg_source(`<rect x="0" y="0" width="8" height="8" fill="currentColor"/>`, "0 0 8 8"),
		0,
		{1, 0.5, 0, 0.5},
	)
	defer image_destroy(&img)
	testing.expect_value(t, err, Conversion_Error.None)
	testing.expect_value(t, img.pixels[0], Rgba8_Pixel{255, 128, 0, 128})
	testing.expect_value(t, img.pixels[len(img.pixels) - 1], Rgba8_Pixel{255, 128, 0, 128})

	// Partial coverage changes alpha only; the colour stays put.
	half, half_err := render_inline(
		svg_source(`<rect x="0" y="0" width="4" height="3.5" fill="currentColor"/>`, "0 0 8 8"),
		0,
		{0.2, 0.4, 1, 1},
	)
	defer image_destroy(&half)
	testing.expect_value(t, half_err, Conversion_Error.None)
	edge := half.pixels[3 * half.width]
	testing.expect_value(t, edge.a, 128)
	testing.expect_value(t, edge.r, 51)
	testing.expect_value(t, edge.g, 102)
	testing.expect_value(t, edge.b, 255)
}

@(test)
overlapping_shapes_composite_source_over :: proc(t: ^testing.T) {
	// Two half-covered layers: 1 - (1-.5)(1-.5) = .75
	img, err := render_inline(
		svg_source(
			`<rect x="0" y="0.5" width="8" height="7.5" fill="currentColor"/><rect x="0" y="0.5" width="8" height="7.5" fill="currentColor"/>`,
			"0 0 8 8",
		),
	)
	defer image_destroy(&img)
	testing.expect_value(t, err, Conversion_Error.None)
	testing.expect_value(t, alpha_at(img, 3, 0), 191)
	testing.expect_value(t, alpha_at(img, 3, 4), 255)
}

@(test)
view_box_offset_and_group_inheritance :: proc(t: ^testing.T) {
	// The rect fills the viewBox exactly, whatever its origin.
	img, err := render_inline(
		svg_source(
			`<g fill="currentColor"><rect x="10" y="10" width="4" height="4"/></g>`,
			"10 10 4 4",
		),
		8,
	)
	defer image_destroy(&img)
	testing.expect_value(t, err, Conversion_Error.None)
	testing.expect_value(t, coverage_sum(img), 64)

	// Non-square viewBox is centred ("meet"): 4x2 into 8x8 leaves bands above and below.
	wide, wide_err := render_inline(
		svg_source(`<rect x="0" y="0" width="4" height="2" fill="currentColor"/>`, "0 0 4 2"),
		8,
	)
	defer image_destroy(&wide)
	testing.expect_value(t, wide_err, Conversion_Error.None)
	testing.expect_value(t, wide.height, 4)
	testing.expect_value(t, coverage_sum(wide), 32)
}

// ---------------------------------------------------------------------------
// Failure modes.
// ---------------------------------------------------------------------------

@(test)
errors_are_reported_not_swallowed :: proc(t: ^testing.T) {
	_, err := rasterize_svg("/nonexistent/nothing.svg")
	testing.expect_value(t, err, Conversion_Error.Read_Failed)
	_, err = rasterize_svg(fmt.tprintf("%s/golden/house.png", TESTDATA))
	testing.expect_value(t, err, Conversion_Error.Read_Failed)

	cases := [?]struct {
		source: string,
		size:   int,
		want:   Conversion_Error,
	} {
		{svg_source(`<text>hi</text>`), 0, .Unsupported_Feature},
		{svg_source(`<path d="M0 0h1" transform="rotate(1)"/>`), 0, .Unsupported_Feature},
		{svg_source(`<path d="M0 0 L"/>`), 0, .Malformed_SVG_Data},
		{`<svg width="24"></svg>`, 0, .Malformed_SVG_Data},
		{`<html></html>`, 0, .Invalid_XML},
		{svg_source(`<path d="M0 0h1"/>`), -1, .Invalid_Output_Size},
		{svg_source(`<path d="M0 0h1"/>`), MAX_OUTPUT_DIMENSION + 1, .Invalid_Output_Size},
		{`<svg viewBox="0 0 1 1" width="1e9" height="1e9"/>`, 0, .Invalid_Output_Size},
	}
	for c in cases {
		img, case_err := render_inline(c.source, c.size)
		testing.expectf(
			t,
			case_err == c.want,
			"%s @%d: expected %v, got %v",
			c.source,
			c.size,
			c.want,
			case_err,
		)
		testing.expect_value(t, len(img.pixels), 0)
	}
}

// ---------------------------------------------------------------------------
// Geometry building blocks.
// ---------------------------------------------------------------------------

path_extent :: proc(commands: string) -> (min, max: Vec2) {
	cmds, _ := parser.parse_path_data(commands, context.temp_allocator)
	path := path_from_commands(cmds)
	defer delete(path)
	subpaths := flatten_path(path, Transform{scale = 1})
	defer {
		for sp in subpaths do delete(sp.points)
		delete(subpaths)
	}

	min, max = {math.INF_F64, math.INF_F64}, {-math.INF_F64, -math.INF_F64}
	for sp in subpaths {
		for p in sp.points {
			min = {math.min(min.x, p.x), math.min(min.y, p.y)}
			max = {math.max(max.x, p.x), math.max(max.y, p.y)}
		}
	}
	return
}

@(test)
arc_flags_pick_the_right_one_of_four_arcs :: proc(t: ^testing.T) {
	// Chord (0,0)-(2,0), radius 2: centres at (1, +-sqrt 3). The extreme point of
	// each arc is 2 - sqrt 3 = 0.268 or 2 + sqrt 3 = 3.732 away from the chord.
	small, large := 2 - math.sqrt(f64(3)), 2 + math.sqrt(f64(3))
	cases := [?]struct {
		cmd:   string,
		min_y: f64,
		max_y: f64,
	} {
		{"M0 0A2 2 0 0 1 2 0", -small, 0},
		{"M0 0A2 2 0 0 0 2 0", 0, small},
		{"M0 0A2 2 0 1 1 2 0", -large, 0},
		{"M0 0A2 2 0 1 0 2 0", 0, large},
	}
	for c in cases {
		lo, hi := path_extent(c.cmd)
		testing.expectf(
			t,
			abs(lo.y - c.min_y) < 2e-3 && abs(hi.y - c.max_y) < 2e-3,
			"%s: y in [%.3f, %.3f], expected [%.3f, %.3f]",
			c.cmd,
			lo.y,
			hi.y,
			c.min_y,
			c.max_y,
		)
	}
}

@(test)
arc_radii_scale_up_when_too_small :: proc(t: ^testing.T) {
	// Radius 1 cannot span 10 units, so it becomes a radius 5 semicircle.
	lo, hi := path_extent("M0 0A1 1 0 0 1 10 0")
	testing.expectf(t, abs(lo.y + 5) < 2e-3 && abs(hi.y) < 1e-9, "y in [%.3f, %.3f]", lo.y, hi.y)

	// Zero radius degenerates to a straight line, per spec.
	lo, hi = path_extent("M0 0A0 5 0 0 1 10 0")
	testing.expect_value(t, lo.y, 0)
	testing.expect_value(t, hi.y, 0)
}

@(test)
arc_rotation_turns_the_ellipse :: proc(t: ^testing.T) {
	// Full ellipse as two arcs between its two ends on the (rotated) major axis.
	// Major radius 5 at 90 degrees means the extent is 10 in y and 4 in x.
	lo, hi := path_extent("M0 -5A2 5 0 0 1 0 5A2 5 0 0 1 0 -5")
	testing.expectf(
		t,
		abs(hi.y - lo.y - 10) < 2e-3 && abs(hi.x - lo.x - 4) < 2e-3,
		"extent %.3f x %.3f",
		hi.x - lo.x,
		hi.y - lo.y,
	)

	// Same ellipse expressed with the axes swapped and a 90 degree rotation.
	lo, hi = path_extent("M0 -5A5 2 90 0 1 0 5A5 2 90 0 1 0 -5")
	testing.expectf(
		t,
		abs(hi.y - lo.y - 10) < 2e-3 && abs(hi.x - lo.x - 4) < 2e-3,
		"rotated extent %.3f x %.3f",
		hi.x - lo.x,
		hi.y - lo.y,
	)
}

@(test)
flattened_circle_stays_within_tolerance :: proc(t: ^testing.T) {
	path := path_from_geometry(parser.Circle{center = {0, 0}, r = 10})
	defer delete(path)
	subpaths := flatten_path(path, Transform{scale = 1})
	defer {
		for sp in subpaths do delete(sp.points)
		delete(subpaths)
	}
	testing.expect_value(t, len(subpaths), 1)
	testing.expect(t, subpaths[0].closed)

	pts := subpaths[0].points[:]
	// Vertices sit on the curve; chord midpoints are the furthest the polyline strays.
	worst := 0.0
	for p, i in pts {
		q := pts[(i + 1) % len(pts)]
		mid := (p + q) / 2
		worst = max(worst, 10 - math.sqrt(mid.x * mid.x + mid.y * mid.y))
		testing.expectf(
			t,
			abs(math.sqrt(p.x * p.x + p.y * p.y) - 10) < 5e-3,
			"vertex %v is off the circle",
			p,
		)
	}
	testing.expectf(t, worst <= FLATTEN_TOLERANCE + 5e-3, "chord deviates by %.4f", worst)
	testing.expect(t, len(pts) > 16, "a 10px radius circle needs a real subdivision")
}

@(test)
path_normalization_handles_relative_and_implicit_moves :: proc(t: ^testing.T) {
	cmds, err := parser.parse_path_data("M1 1h2v2H1zl1 0", context.temp_allocator)
	testing.expect_value(t, err, parser.Svg_Error.None)
	path := path_from_commands(cmds)
	defer delete(path)

	want := [?]struct {
		kind: Segment_Kind,
		at:   Vec2,
	} {
		{.Move, {1, 1}},
		{.Line, {3, 1}},
		{.Line, {3, 3}},
		{.Line, {1, 3}},
		{.Close, {}},
		{.Move, {1, 1}},
		{.Line, {2, 1}},
	}
	if !testing.expect_value(t, len(path), len(want)) do return
	for w, i in want {
		testing.expect_value(t, path[i].kind, w.kind)
		if w.kind != .Close do testing.expect_value(t, path[i].p[0], w.at)
	}
}

@(test)
smooth_curves_reflect_the_previous_control_point :: proc(t: ^testing.T) {
	cmds, _ := parser.parse_path_data("M0 0C1 1 2 1 3 0S5 -1 6 0", context.temp_allocator)
	path := path_from_commands(cmds)
	defer delete(path)
	// First control point of S is the reflection of (2,1) through (3,0).
	testing.expect_value(t, path[2].p[0], Vec2{4, -1})

	// A lone S, with no cubic before it, reflects nothing.
	cmds, _ = parser.parse_path_data("M0 0S1 1 2 0", context.temp_allocator)
	lone := path_from_commands(cmds)
	defer delete(lone)
	testing.expect_value(t, lone[1].p[0], Vec2{0, 0})

	cmds, _ = parser.parse_path_data("M0 0Q1 1 2 0T4 0", context.temp_allocator)
	quads := path_from_commands(cmds)
	defer delete(quads)
	// T's implied control is (3,-1); as a cubic from (2,0): c1 = (2,0) + 2/3 * (1,-1).
	testing.expect(
		t,
		abs(quads[2].p[0].x - (2 + 2.0 / 3.0)) < 1e-12 && abs(quads[2].p[0].y + 2.0 / 3.0) < 1e-12,
	)
}

@(test)
view_transform_fits_and_centres :: proc(t: ^testing.T) {
	xf := view_transform({0, 0, 24, 24}, 48, 48)
	testing.expect_value(t, xf.scale, 2)
	testing.expect_value(t, xf.offset, Vec2{0, 0})

	xf = view_transform({10, 20, 4, 2}, 8, 8)
	testing.expect_value(t, xf.scale, 2)
	testing.expect_value(t, transform_point(xf, {10, 20}), Vec2{0, 2})
	testing.expect_value(t, transform_point(xf, {14, 22}), Vec2{8, 6})
}
