package meta

import "core:fmt"
import "core:strings"

// TODO: Read these from a file at some point in the future
HEADER :: `package %s

import "core:fmt"

%s :: enum {
  $ENUMS_ITER
}
`


Meta :: struct {
	literal: string,
}

Meta_Queue :: struct {
	queue: [dynamic]string,
}


// Combines all instances of the `OUTPUT_FILENAME`.odin
meta_formatter :: proc(sb: ^strings.Builder) {}


// Pulls all appropriate formatter/template information together,
// waits for queues, builds strings, frees space, etc.
meta_builder :: proc(sb: ^strings.Builder, args: [dynamic]string = nil) -> Meta {
	template_literal: string

	// Inject the parts of the template that make sense
	//  ---
	// HEADER
	fmt.sbprintf(sb, HEADER, "main", "Lucide_Icons", "{\n  $ENUMS_ITER\n}")

	// Return everything safely by allocating a clean copy of the built string
	template_literal = strings.clone(strings.to_string(sb^), context.allocator)
	return Meta{literal = template_literal}
}


meta_init :: proc() -> Meta {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	// mq: Meta_Queue
	// defer delete(mq.queue)

	meta := meta_builder(&sb)
	return meta
}
