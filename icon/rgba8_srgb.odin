package icon

// Core of the application
//
// This is the SVG to rgba8 converter main logic.
// Functions in this file will be treated strictly as a Lucide rasterizer
// more than a general-purpose SVG parser.

import "../parser"
import "core:encoding/xml"
import "core:log"
import "core:math"
import "core:mem"

BLACK :: [4]f32{0, 0, 0, 1}

// Guards against a corrupt width/height turning into a multi-gig buffer...
MAX_OUTPUT_DIMENSION :: 4096

Rgba8_Pixel :: struct {
	r: u8,
	g: u8,
	b: u8,
	a: u8,
}

// Straight (non-premultiplied) alpha. Colour channels are sRGB-encoded;
// alpha is plain linear coverage.
Image_Buffer :: struct {
	width:     int,
	height:    int,
	pixels:    []Rgba8_Pixel,
	allocator: mem.Allocator,
}

Conversion_Error :: enum {
	None,
	Invalid_XML,
	Malformed_SVG_Data,
	Unsupported_Feature,
	Read_Failed,
	Invalid_Output_Size,
	Allocation_Failed,
}

SVG :: struct {
	name:        string,
	output_path: string,
	color:       [4]f32, // Skald's `Color` type
}

// Rasterizes the .svg at `path`. `size` is the output width in pixels (height
// follows the SVG's aspect ratio); 0 keeps the SVG's own width and height.
// `color` is what `currentColor` resolves to, as straight RGBA in [0, 1].
// The caller owns the result: free it with `image_destroy`.
rasterize_svg :: proc(
	path: string,
	size := 0,
	color := BLACK,
	allocator := context.allocator,
) -> (
	img: Image_Buffer,
	err: Conversion_Error,
) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	ok, message, doc := parser.read_svg(path)
	if !ok {
		log.warn(message)
		return {}, .Read_Failed
	}
	return render_document(doc, size, color, allocator)
}

// Same as `rasterize_svg`, for a document that is already parsed.
rasterize_document :: proc(
	doc: ^xml.Document,
	size := 0,
	color := BLACK,
	allocator := context.allocator,
) -> (
	img: Image_Buffer,
	err: Conversion_Error,
) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	return render_document(doc, size, color, allocator)
}

// Convenience for callers that only want the bytes: width * height * 4 of them.
// Free with `delete(bytes, allocator)`.
svg_to_rgba8 :: proc(
	path: string,
	size := 0,
	color := BLACK,
	allocator := context.allocator,
) -> (
	bytes: []u8,
	width, height: int,
	err: Conversion_Error,
) {
	img := rasterize_svg(path, size, color, allocator) or_return
	return image_bytes(img), img.width, img.height, .None
}

image_bytes :: proc(img: Image_Buffer) -> []u8 {
	return mem.slice_to_bytes(img.pixels)
}

image_destroy :: proc(img: ^Image_Buffer) {
	delete(img.pixels, img.allocator)
	img^ = {}
}

// Everything except the returned pixels is allocated from `context.allocator`
@(private)
render_document :: proc(
	doc: ^xml.Document,
	size: int,
	color: [4]f32,
	allocator: mem.Allocator,
) -> (
	img: Image_Buffer,
	err: Conversion_Error,
) {
	svg, parse_err := parser.parse_svg(doc)
	if parse_err != .None do return {}, conversion_error(parse_err)

	width, height := output_size(svg, size) or_return
	count := width * height

	pixels, alloc_err := make([]Rgba8_Pixel, count, allocator)
	if alloc_err != nil do return {}, .Allocation_Failed

	canvas := make([][4]f32, count)
	coverage := make([]f32, count)
	edges := make([dynamic]Edge, 0, 256)
	transform := view_transform(svg.view_box, width, height)

	for shape in svg.shapes {
		style := shape.style
		subpaths := flatten_path(path_from_geometry(shape.geometry), transform)

		if style.fill != .None {
			clear(&edges)
			for sp in subpaths {
				if len(sp.points) >= 3 do polygon_edges(&edges, sp.points[:])
			}
			if len(edges) > 0 {
				fill_coverage(edges[:], style.fill_rule, width, height, coverage)
				composite(canvas, coverage, color)
			}
		}

		if style.stroke != .None && style.stroke_width > 0 {
			clear(&edges)
			stroke_subpaths(
				subpaths[:],
				Stroke_Params {
					half_width = style.stroke_width * transform.scale / 2,
					cap = style.line_cap,
					join = style.line_join,
					miter_limit = style.miter_limit,
				},
				&edges,
			)
			if len(edges) > 0 {
				fill_coverage(edges[:], .Non_Zero, width, height, coverage)
				composite(canvas, coverage, color)
			}
		}
	}

	resolve_pixels(canvas, pixels)
	return Image_Buffer{width = width, height = height, pixels = pixels, allocator = allocator},
		.None
}

@(private)
conversion_error :: proc(e: parser.Svg_Error) -> Conversion_Error {
	switch e {
	case .None:
		return .None
	case .Invalid_XML:
		return .Invalid_XML
	case .Unsupported_Element, .Unsupported_Feature:
		return .Unsupported_Feature
	case .Invalid_View_Box, .Invalid_Number, .Invalid_Path_Data, .Invalid_Attribute:
		return .Malformed_SVG_Data
	}
	return .Malformed_SVG_Data
}

@(private)
output_size :: proc(svg: parser.Svg, size: int) -> (width, height: int, err: Conversion_Error) {
	if size < 0 do return 0, 0, .Invalid_Output_Size

	w, h := svg.width, svg.height
	if size > 0 {
		h = f64(size) * svg.height / svg.width
		w = f64(size)
	}
	width, height = int(math.round(w)), max(1, int(math.round(h)))
	if width < 1 || width > MAX_OUTPUT_DIMENSION || height > MAX_OUTPUT_DIMENSION {
		return 0, 0, .Invalid_Output_Size
	}
	return width, height, .None
}

// preserveAspectRatio="xMidYMid meet", the SVG default.
@(private)
view_transform :: proc(view_box: [4]f64, width, height: int) -> Transform {
	scale := min(f64(width) / view_box[2], f64(height) / view_box[3])
	return Transform {
		scale = scale,
		offset = {
			(f64(width) - view_box[2] * scale) / 2 - view_box[0] * scale,
			(f64(height) - view_box[3] * scale) / 2 - view_box[1] * scale,
		},
	}
}

// Premultiplied float canvas to straight-alpha bytes.
@(private)
resolve_pixels :: proc(canvas: [][4]f32, pixels: []Rgba8_Pixel) {
	to_byte :: proc(v: f32) -> u8 {
		return u8(clamp(v, 0, 1) * 255 + 0.5)
	}

	for c, i in canvas {
		alpha := to_byte(c.a)
		if alpha == 0 {
			pixels[i] = {}
			continue
		}
		pixels[i] = {to_byte(c.r / c.a), to_byte(c.g / c.a), to_byte(c.b / c.a), alpha}
	}
}
