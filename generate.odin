package main

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:terminal/ansi"

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

	strings.write_string(&sb, "package main\n\nLucide_Icons :: enum {\n")

	for info in infos {
		if !os.is_dir(info.fullpath) {
			base := filepath.stem(info.name)
			clean_name := strings.to_ada_case(base, context.temp_allocator) // Example sanitization
			fmt.sbprintfln(&sb, "\t%s,", clean_name)
		}
	}

	strings.write_string(&sb, "}\n")

	transmuted_data := transmute([]u8)strings.to_string(sb)

	if args.test {
		print_test_banner("lucide-skald.odin", string(transmuted_data))
	} else {
		write_err := os.write_entire_file("lucide.odin", transmuted_data)
		fmt.printf("Could not read directory: %s", args.path)
	}
}

main :: proc() {
	args: Args
	flags.parse_or_exit(&args, os.args)

	context.logger = log.create_console_logger(
		opt = log.Default_Console_Logger_Opts - {.Terminal_Color} + {.Date} - {.Procedure},
	)
	defer log.destroy_console_logger(context.logger)

	// TODO: Need to add some pre-flight checks... at some point...
	icon_enum_generation(args)
}
