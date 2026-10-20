package meta

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:terminal/ansi"

// NOTE: Changing this would introduced a Breaking Change into the Release,
// as this is the exposed library name.
OUTPUT_FILENAME :: "lucide"

RESET :: ansi.CSI + ansi.RESET + ansi.SGR
BOLD :: ansi.CSI + ansi.BOLD + ansi.SGR
DIM :: ansi.CSI + ansi.FAINT + ansi.SGR
CYAN :: ansi.CSI + ansi.FG_CYAN + ansi.SGR
GREEN :: ansi.CSI + ansi.FG_GREEN + ansi.SGR

RULE :: "──────────────────────────────────────────────"

Args :: struct {
	// Lucide-Icon input directory (where the icons are stored)
	path: string `args:"name=path,required" usage:"Directory path where icons are stored"`,
	// NOTE: No 'Output' directory must always be the same, so the generator can feed
	// the library properly
	test: bool `args:"name=test" usage:"Outputs generated file contents to stdout. Does not write to file."`,
}

// Little test banner thing, makes seeing the long output much easier.
// TODO: Is it possible to redirect this to `less` or another pager?
print_test_banner :: proc(source, data: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(
		&b,
		"\n%s╭─ %s●%s %sTEST OUTPUT%s %s%s%s\n",
		CYAN,
		GREEN,
		CYAN,
		BOLD,
		RESET,
		CYAN,
		RULE,
		RESET,
	)
	fmt.sbprintf(
		&b,
		"%s│%s %sGenerated enum output from%s %s%s%s\n",
		CYAN,
		RESET,
		DIM,
		RESET,
		GREEN,
		source,
		RESET,
	)
	fmt.sbprintf(&b, "%s├%s%s\n", CYAN, RULE, RESET)

	it := data
	for line in strings.split_lines_iterator(&it) {
		fmt.sbprintf(&b, "%s│%s %s\n", CYAN, RESET, line)
	}

	fmt.sbprintf(&b, "%s╰%s%s", CYAN, RULE, RESET)
	log.infof("%s", strings.to_string(b))
}

// Takes directory path to entire `lucide-icons`, iterates through all .svg files,
// and create enums of each file icon.
icon_enum_generation :: proc(args: Args) {
	dir_path := args.path

	handle, err := os.open(dir_path)
	if err != os.ERROR_NONE do return

	defer os.close(handle)

	infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != os.ERROR_NONE do return

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	Inline_Parse :: struct {
		file_obj: os.File_Info,
		base:     string,
		ext:      string,
	}

	// May be useful for later, but we'll split up the .json and .svg files
	// for better future parsing.
	json_exts: [dynamic]Inline_Parse
	svg_exts: [dynamic]Inline_Parse
	defer delete(json_exts)
	defer delete(svg_exts)

	for info in infos {
		if !os.is_dir(info.fullpath) {
			base := filepath.stem(info.name)
			ext := filepath.ext(info.name)

			// Just gonne grab the whole object right now, and divvy things up
			// so we're not having to split logic later on down the line.
			//
			// `file_obj` is mainly captured for future processing
			append(
				ext == ".svg" ? &svg_exts : &json_exts,
				Inline_Parse{file_obj = info, base = base, ext = ext},
			)
		}
	}

	// We only want to create enums for files that are SVGs, because those
	// are the icons that we'll be referencing in our UI's.
	for svg, i in svg_exts {
		// json_exts[i] -> Accompanied JSON file (lucide's category and tag information)
		// ^ (assuming that lucide included a proper JSON file for each icon)
		//
		// Could also do either comparison lookup, or something else
		clean_name := strings.to_ada_case(svg.base, context.temp_allocator) // Example sanitization
		fmt.sbprintfln(&sb, "\t%s,", clean_name)
		log.debug("Parsed enum: ", clean_name)
	}
	strings.write_string(&sb, "}\n")

	transmuted_data := transmute([]u8)strings.to_string(sb)

	write_err := os.write_entire_file(OUTPUT_FILENAME + ".odin", transmuted_data)
	fmt.printf("Could not read directory: %s", args.path)
}


main :: proc() {
	args: Args
	flags.parse_or_exit(&args, os.args)

	context.logger = log.create_console_logger(
		opt = log.Default_Console_Logger_Opts - {.Terminal_Color} + {.Date} - {.Procedure},
	)
	defer log.destroy_console_logger(context.logger)

	m := meta_init()

	fmt.printfln("%s", m.literal)

	// TODO: Need to add some pre-flight checks... at some point...
	icon_enum_generation(args)
}
