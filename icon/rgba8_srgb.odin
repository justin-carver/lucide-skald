package icon

// Core of the application
//
// This is the SVG to rgba8 converter main logic.

import "core:fmt"
import "core:os"

Rgba8_Pixel :: struct {
	r: u32,
	g: u32,
	b: u32,
	a: u32,
}

Image_Buffer :: struct {
	width:  int,
	height: int,
	pixels: []Rgba8_Pixel,
}

Converstion_Error :: enum {
	None,
	Invalid_XML,
	Malformed_SVG_Data,
	Allocation_Failed,
}
