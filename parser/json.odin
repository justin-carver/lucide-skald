package parser

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// NOTE: May not be needed, but may be good to have later for data.
// Parsed directly from .json files within @lucide/icons/
Icon_Data :: struct {
	contributors: []string,
	use_cases:    []string,
	tags:         []string,
	categories:   []string,
}

// Reads a JSON file from a `path` string and returns an object containing:
// `status` - was the JSON file parsed properly
// `message` - useful debugging/error information
// `payload` - the root JSON object of the parsed path file
read_json :: proc(path: string) -> (status: bool, message: string, payload: json.Object) {
	if !strings.contains(strings.to_lower(path), ".json") do return false, fmt.tprintf("Not a valid .JSON file: %s\nCheck the file extension.", path), nil
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)

	if read_err != nil {
		return false, fmt.tprintf("Failed to load the file: %s", path), nil
	}

	json_data, err := json.parse(data)

	if err != .None {
		return false, fmt.tprint("Failed to parse JSON from file.\nError: %s", err), nil
	}

	root, ok := json_data.(json.Object)
	if !ok {
		json.destroy_value(root)
		return false, fmt.tprintf("Expected a JSON object at top-level: %s", path), nil
	}

	return true, "", root
}
