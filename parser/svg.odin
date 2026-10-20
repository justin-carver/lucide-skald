package parser

import "core:encoding/xml"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// XML <-> SVG parser.
// These will get used interchangibly throughout the file...
//
// PRs welcome...

Vec2 :: [2]f64

Svg_Error :: enum {
	None,
	Invalid_XML,
	Invalid_View_Box,
	Invalid_Number,
	Invalid_Path_Data,
	Invalid_Attribute,
	Unsupported_Element,
	Unsupported_Feature,
}

Paint :: enum u8 {
	None,
	Current_Color,
}

Line_Cap :: enum u8 {
	Butt,
	Round,
	Square,
}

Line_Join :: enum u8 {
	Miter,
	Round,
	Bevel,
}

Fill_Rule :: enum u8 {
	Non_Zero,
	Even_Odd,
}

Style :: struct {
	fill:         Paint,
	stroke:       Paint,
	stroke_width: f64,
	line_cap:     Line_Cap,
	line_join:    Line_Join,
	miter_limit:  f64,
	fill_rule:    Fill_Rule,
}

// The spec default fill is black. Following currentColor instead keeps an
// unstyled shape on the caller's tint.
DEFAULT_STYLE :: Style {
	fill         = .Current_Color,
	stroke       = .None,
	stroke_width = 1,
	line_cap     = .Butt,
	line_join    = .Miter,
	miter_limit  = 4,
	fill_rule    = .Non_Zero,
}

Path_Shape :: struct {
	commands: []Path_Command,
}

Circle :: struct {
	center: Vec2,
	r:      f64,
}

Ellipse :: struct {
	center: Vec2,
	radii:  Vec2,
}

// `radii` is already resolved (rx/ry fallback and clamping to half the size).
Rect :: struct {
	origin: Vec2,
	size:   Vec2,
	radii:  Vec2,
}

Line :: struct {
	a, b: Vec2,
}

Poly :: struct {
	points: []Vec2,
	closed: bool,
}

Geometry :: union {
	Path_Shape,
	Circle,
	Ellipse,
	Rect,
	Line,
	Poly,
}

Svg_Shape :: struct {
	geometry: Geometry,
	style:    Style,
}

Svg :: struct {
	view_box: [4]f64, // x, y, width, height
	width:    f64,
	height:   f64,
	shapes:   [dynamic]Svg_Shape,
}

// Presentation attributes that would change the picture but are not modelled.
// Failing on them beats silently rendering something different from upstream.
@(private)
UNSUPPORTED_ATTRIBUTES :: [?]string {
	"transform",
	"style",
	"opacity",
	"fill-opacity",
	"stroke-opacity",
	"stroke-dasharray",
	"stroke-dashoffset",
	"clip-path",
	"mask",
	"filter",
	"vector-effect",
	"display",
	"visibility",
}

read_svg :: proc(path: string) -> (status: bool, message: string, payload: ^xml.Document) {
	if !strings.equal_fold(filepath.ext(path), ".svg") do return false, fmt.tprintf("Not a valid .SVG file: %s\nCheck the file extension.", path), nil
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)

	if read_err != nil {
		return false, fmt.tprintf("Failed to load the file: %s", path), nil
	}

	xml_data, err := xml.parse(
		data,
		xml.Options{flags = {.Ignore_Unsupported}, expected_doctype = ""},
	)

	if err != .None {
		return false, fmt.tprintf("Failed to parse XML from file.\nError: %v", err), nil
	}

	return true, "", xml_data
}

parse_svg :: proc(
	doc: ^xml.Document,
	allocator := context.allocator,
) -> (
	svg: Svg,
	err: Svg_Error,
) {
	context.allocator = allocator

	if doc == nil || doc.element_count == 0 do return svg, .Invalid_XML
	root := doc.elements[0]
	if root.ident != "svg" do return svg, .Invalid_XML

	style := DEFAULT_STYLE
	apply_style(&style, root.attribs) or_return

	width, has_width := attr(root.attribs, "width")
	height, has_height := attr(root.attribs, "height")
	if has_width {
		svg.width = parse_length(width) or_return
	}
	if has_height {
		svg.height = parse_length(height) or_return
	}

	if view_box, found := attr(root.attribs, "viewBox"); found {
		values, ok := parse_number_list(view_box)
		if !ok || len(values) != 4 || values[2] <= 0 || values[3] <= 0 do return svg, .Invalid_View_Box
		svg.view_box = {values[0], values[1], values[2], values[3]}
	} else if has_width && has_height && svg.width > 0 && svg.height > 0 {
		svg.view_box = {0, 0, svg.width, svg.height}
	} else {
		return svg, .Invalid_View_Box
	}

	if !has_width do svg.width = svg.view_box[2]
	if !has_height do svg.height = svg.view_box[3]
	if svg.width <= 0 || svg.height <= 0 do return svg, .Invalid_Attribute

	svg.shapes = make([dynamic]Svg_Shape)
	walk_children(doc, 0, style, &svg) or_return
	return svg, .None
}

@(private)
walk_children :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	style: Style,
	svg: ^Svg,
) -> (
	err: Svg_Error,
) {
	for value in doc.elements[id].value {
		child_id, is_element := value.(xml.Element_ID)
		if !is_element do continue

		el := doc.elements[child_id]
		if el.kind != .Element do continue

		switch el.ident {
		case "title", "desc", "metadata":
			continue
		case "g":
			group_style := style
			apply_style(&group_style, el.attribs) or_return
			walk_children(doc, child_id, group_style, svg) or_return
		case "path", "circle", "ellipse", "rect", "line", "polyline", "polygon":
			shape_style := style
			apply_style(&shape_style, el.attribs) or_return
			geometry, visible := parse_geometry(el) or_return
			if visible do append(&svg.shapes, Svg_Shape{geometry = geometry, style = shape_style})
		case:
			log.warnf("svg: unsupported element <%s>", el.ident)
			return .Unsupported_Element
		}
	}
	return .None
}

// `visible` is false for shapes the spec disables (zero size) or that have no data.
@(private)
parse_geometry :: proc(el: xml.Element) -> (geometry: Geometry, visible: bool, err: Svg_Error) {
	switch el.ident {
	case "path":
		d, found := attr(el.attribs, "d")
		if !found do return nil, false, .None
		cmds := parse_path_data(d) or_return
		return Path_Shape{commands = cmds}, true, .None

	case "circle":
		cx := number_attr(el.attribs, "cx") or_return
		cy := number_attr(el.attribs, "cy") or_return
		r := number_attr(el.attribs, "r") or_return
		if r < 0 do return nil, false, .Invalid_Attribute
		return Circle{center = {cx, cy}, r = r}, r > 0, .None

	case "ellipse":
		cx := number_attr(el.attribs, "cx") or_return
		cy := number_attr(el.attribs, "cy") or_return
		rx := number_attr(el.attribs, "rx") or_return
		ry := number_attr(el.attribs, "ry") or_return
		if rx < 0 || ry < 0 do return nil, false, .Invalid_Attribute
		return Ellipse{center = {cx, cy}, radii = {rx, ry}}, rx > 0 && ry > 0, .None

	case "rect":
		x := number_attr(el.attribs, "x") or_return
		y := number_attr(el.attribs, "y") or_return
		w := number_attr(el.attribs, "width") or_return
		h := number_attr(el.attribs, "height") or_return
		if w < 0 || h < 0 do return nil, false, .Invalid_Attribute

		rx, ry: f64
		_, has_rx := attr(el.attribs, "rx")
		_, has_ry := attr(el.attribs, "ry")
		if has_rx do rx = number_attr(el.attribs, "rx") or_return
		if has_ry do ry = number_attr(el.attribs, "ry") or_return
		if rx < 0 || ry < 0 do return nil, false, .Invalid_Attribute
		if has_rx && !has_ry do ry = rx
		if has_ry && !has_rx do rx = ry
		rx, ry = min(rx, w / 2), min(ry, h / 2)
		return Rect{origin = {x, y}, size = {w, h}, radii = {rx, ry}}, w > 0 && h > 0, .None

	case "line":
		x1 := number_attr(el.attribs, "x1") or_return
		y1 := number_attr(el.attribs, "y1") or_return
		x2 := number_attr(el.attribs, "x2") or_return
		y2 := number_attr(el.attribs, "y2") or_return
		return Line{a = {x1, y1}, b = {x2, y2}}, true, .None

	case "polyline", "polygon":
		raw, found := attr(el.attribs, "points")
		if !found do return nil, false, .None
		values, ok := parse_number_list(raw)
		if !ok || len(values) % 2 != 0 do return nil, false, .Invalid_Attribute

		points := make([]Vec2, len(values) / 2)
		for i in 0 ..< len(points) {
			points[i] = {values[2 * i], values[2 * i + 1]}
		}
		return Poly{points = points, closed = el.ident == "polygon"}, len(points) >= 2, .None
	}
	return nil, false, .Unsupported_Element
}

@(private)
apply_style :: proc(style: ^Style, attribs: xml.Attributes) -> (err: Svg_Error) {
	for a in attribs {
		for banned in UNSUPPORTED_ATTRIBUTES {
			if a.key == banned {
				log.warnf("svg: unsupported attribute %s=%q", a.key, a.val)
				return .Unsupported_Feature
			}
		}

		switch a.key {
		case "fill":
			style.fill = parse_paint(a.val) or_return
		case "stroke":
			style.stroke = parse_paint(a.val) or_return
		case "stroke-width":
			style.stroke_width = parse_length(a.val) or_return
			if style.stroke_width < 0 do return .Invalid_Attribute
		case "stroke-miterlimit":
			style.miter_limit = parse_length(a.val) or_return
			if style.miter_limit < 1 do return .Invalid_Attribute
		case "stroke-linecap":
			switch a.val {
			case "butt":
				style.line_cap = .Butt
			case "round":
				style.line_cap = .Round
			case "square":
				style.line_cap = .Square
			case:
				return .Invalid_Attribute
			}
		case "stroke-linejoin":
			switch a.val {
			case "miter":
				style.line_join = .Miter
			case "round":
				style.line_join = .Round
			case "bevel":
				style.line_join = .Bevel
			case:
				return .Unsupported_Feature // miter-clip, arcs
			}
		case "fill-rule":
			switch a.val {
			case "nonzero":
				style.fill_rule = .Non_Zero
			case "evenodd":
				style.fill_rule = .Even_Odd
			case:
				return .Invalid_Attribute
			}
		}
	}
	return .None
}

@(private)
parse_paint :: proc(s: string) -> (paint: Paint, err: Svg_Error) {
	value := strings.trim_space(s)
	switch {
	case strings.equal_fold(value, "none"):
		return .None, .None
	case strings.equal_fold(value, "currentColor"):
		return .Current_Color, .None
	}
	log.warnf("svg: unsupported paint %q", s)
	return .None, .Unsupported_Feature
}

@(private)
attr :: proc(attribs: xml.Attributes, key: string) -> (val: string, found: bool) {
	for a in attribs {
		if a.key == key do return a.val, true
	}
	return "", false
}

@(private)
number_attr :: proc(attribs: xml.Attributes, key: string) -> (value: f64, err: Svg_Error) {
	s, found := attr(attribs, key)
	if !found do return 0, .None
	return parse_length(s)
}

// Plain numbers and `px` only. Percentages and font-relative units depend on
// context this renderer does not have.
@(private)
parse_length :: proc(s: string) -> (value: f64, err: Svg_Error) {
	trimmed := strings.trim_suffix(strings.trim_space(s), "px")
	end, ok := scan_number(trimmed, 0)
	if !ok || end != len(trimmed) do return 0, .Invalid_Number
	value, ok = strconv.parse_f64(trimmed)
	if !ok do return 0, .Invalid_Number
	return value, .None
}
