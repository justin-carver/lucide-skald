package parser

import "core:encoding/xml"
import "core:testing"

@(test)
path_data_packed_numbers :: proc(t: ^testing.T) {
	// ".5.5" is two numbers, "4-9" is 4 and -9, and the arc flags are glued.
	cmds, err := parse_path_data("m.5.5 4-9a2 2 0 011 1.5", context.temp_allocator)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, len(cmds), 3)
	testing.expect_value(t, cmds[0], Path_Command{op = 'm', args = {0.5, 0.5, 0, 0, 0, 0, 0}})
	testing.expect_value(t, cmds[1], Path_Command{op = 'l', args = {4, -9, 0, 0, 0, 0, 0}})
	testing.expect_value(t, cmds[2], Path_Command{op = 'a', args = {2, 2, 0, 0, 1, 1, 1.5}})
}

@(test)
path_data_arc_flags :: proc(t: ^testing.T) {
	cmds, err := parse_path_data("M0 0a2.5 2.5 0 1 1-4 2.03", context.temp_allocator)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, cmds[1].args, [7]f64{2.5, 2.5, 0, 1, 1, -4, 2.03})

	cmds, err = parse_path_data("M0 0A1 1 0 1010 10", context.temp_allocator)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, cmds[1].args, [7]f64{1, 1, 0, 1, 0, 10, 10})
}

@(test)
path_data_implicit_repeats :: proc(t: ^testing.T) {
	cmds, err := parse_path_data("M1 2 3 4 5 6 h1 2z", context.temp_allocator)
	testing.expect_value(t, err, Svg_Error.None)
	ops: [8]u8
	for c, i in cmds do ops[i] = c.op
	testing.expect_value(t, ops, [8]u8{'M', 'L', 'L', 'h', 'h', 'z', 0, 0})
}

@(test)
path_data_exponents_and_separators :: proc(t: ^testing.T) {
	cmds, err := parse_path_data("M1e1,2E-1L+3 .5", context.temp_allocator)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, cmds[0].args[0], 10)
	testing.expect_value(t, cmds[0].args[1], 0.2)
	testing.expect_value(t, cmds[1].args[0], 3)
}

@(test)
path_data_rejects_garbage :: proc(t: ^testing.T) {
	bad := [?]string {
		"",
		"L1 1",
		"M1",
		"M1 2 3",
		"M1 2 z 3",
		"M1 2 L,3 4",
		"M1 2 L3,,4",
		"M1 2,",
		"M1 2 ,L3 4",
		"M1 2,L3 4",
		"M1 2 X",
		"M1 2 a1 1 0 2 0 1 1",
		"M1 2 L1e 3",
		"M nan 2",
	}
	for d in bad {
		_, err := parse_path_data(d, context.temp_allocator)
		testing.expectf(t, err == .Invalid_Path_Data, "expected %q to be rejected, got %v", d, err)
	}
}

@(test)
number_list :: proc(t: ^testing.T) {
	values, ok := parse_number_list(" 3 11  22,2 13 21 ", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(values), 6)
	testing.expect_value(t, values[3], 2)

	_, ok = parse_number_list("1 2 x", context.temp_allocator)
	testing.expect(t, !ok)
}

parse_test_svg :: proc(source: string) -> (svg: Svg, err: Svg_Error) {
	doc, xml_err := xml.parse(source, allocator = context.temp_allocator)
	if xml_err != .None do return {}, .Invalid_XML
	return parse_svg(doc, context.temp_allocator)
}

@(test)
svg_inherits_and_overrides_style :: proc(t: ^testing.T) {
	svg, err := parse_test_svg(
		`<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
			<g stroke-width="3"><circle cx="1" cy="2" r=".5" fill="currentColor"/></g>
			<line x1="0" y1="0" x2="1" y2="1"/>
		</svg>`,
	)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, len(svg.shapes), 2)
	testing.expect_value(t, svg.shapes[0].style.fill, Paint.Current_Color)
	testing.expect_value(t, svg.shapes[0].style.stroke_width, 3)
	testing.expect_value(t, svg.shapes[1].style.fill, Paint.None)
	testing.expect_value(t, svg.shapes[1].style.stroke_width, 2)
	testing.expect_value(t, svg.shapes[1].style.line_cap, Line_Cap.Round)
}

@(test)
svg_rect_radius_rules :: proc(t: ^testing.T) {
	svg, err := parse_test_svg(
		`<svg viewBox="0 0 24 24">
			<rect x="1" y="1" width="10" height="4" ry="1"/>
			<rect x="1" y="1" width="10" height="4" rx="9"/>
			<rect x="1" y="1" width="0" height="4"/>
		</svg>`,
	)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, len(svg.shapes), 2) // zero width disables the third
	testing.expect_value(t, svg.shapes[0].geometry.(Rect).radii, Vec2{1, 1})
	testing.expect_value(t, svg.shapes[1].geometry.(Rect).radii, Vec2{5, 2})
}

@(test)
svg_sizes_fall_back_to_view_box :: proc(t: ^testing.T) {
	svg, err := parse_test_svg(`<svg viewBox="0 0 16 8"></svg>`)
	testing.expect_value(t, err, Svg_Error.None)
	testing.expect_value(t, svg.width, 16)
	testing.expect_value(t, svg.height, 8)

	_, err = parse_test_svg(`<svg></svg>`)
	testing.expect_value(t, err, Svg_Error.Invalid_View_Box)
}

@(test)
svg_fails_on_unsupported_input :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: string,
		want:   Svg_Error,
	} {
		{`<svg viewBox="0 0 1 1"><text>hi</text></svg>`, .Unsupported_Element},
		{
			`<svg viewBox="0 0 1 1"><path d="M0 0L1 1" transform="scale(2)"/></svg>`,
			.Unsupported_Feature,
		},
		{`<svg viewBox="0 0 1 1" fill="url(#a)"><path d="M0 0L1 1"/></svg>`, .Unsupported_Feature},
		{`<svg viewBox="0 0 1 1"><path d="M0 0 L"/></svg>`, .Invalid_Path_Data},
		{`<svg viewBox="0 0 1 1"><circle r="-1"/></svg>`, .Invalid_Attribute},
		{`<svg viewBox="0 0 1 1"><circle r="5em"/></svg>`, .Invalid_Number},
		{`<svg viewBox="0 0 1 1"><polygon points="1 2 3"/></svg>`, .Invalid_Attribute},
		{`<html></html>`, .Invalid_XML},
	}
	for c in cases {
		_, err := parse_test_svg(c.source)
		testing.expectf(t, err == c.want, "%s: expected %v, got %v", c.source, c.want, err)
	}
}
