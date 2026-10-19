package parser

import "core:strconv"

// Raw `d` attribute data. `op` keeps the original letter (case = relative/absolute)
// and unused trailing `args` stay zero. Implicit repeats are already expanded,
// with a repeated M/m turned into L/l as the spec demands.
Path_Command :: struct {
	op:   u8,
	args: [7]f64,
}

parse_path_data :: proc(d: string, allocator := context.allocator) -> (cmds: []Path_Command, err: Svg_Error) {
	out := make([dynamic]Path_Command, 0, 16, allocator)
	pos := 0
	op: u8
	after_number := false // a comma is only legal between two numbers

	for {
		comma: bool
		pos, comma = skip_separators(d, pos, after_number)
		if pos >= len(d) {
			if comma do return nil, .Invalid_Path_Data
			break
		}

		if c := d[pos]; is_path_command(c) {
			if comma || (len(out) == 0 && c != 'M' && c != 'm') do return nil, .Invalid_Path_Data
			op = c
			pos += 1
			after_number = false
		} else {
			switch op {
			case 0, 'Z', 'z': return nil, .Invalid_Path_Data
			case 'M': op = 'L'
			case 'm': op = 'l'
			}
		}

		cmd := Path_Command {
			op = op,
		}
		for k in 0 ..< path_arg_count(op) {
			pos, _ = skip_separators(d, pos, after_number)
			ok: bool
			// Arc flags are single characters, so "a1 1 0 011 1" is legal.
			if (op == 'A' || op == 'a') && (k == 3 || k == 4) {
				cmd.args[k], pos, ok = read_flag(d, pos)
			} else {
				cmd.args[k], pos, ok = read_number(d, pos)
			}
			if !ok do return nil, .Invalid_Path_Data
			after_number = true
		}
		append(&out, cmd)
	}

	if len(out) == 0 do return nil, .Invalid_Path_Data
	return out[:], .None
}

parse_number_list :: proc(s: string, allocator := context.allocator) -> (values: []f64, ok: bool) {
	out := make([dynamic]f64, 0, 8, allocator)
	pos, _ := skip_separators(s, 0, false)
	for pos < len(s) {
		value: f64
		value, pos, ok = read_number(s, pos)
		if !ok do return nil, false
		append(&out, value)

		comma: bool
		pos, comma = skip_separators(s, pos, true)
		if comma && pos >= len(s) do return nil, false
	}
	return out[:], true
}

@(private)
path_arg_count :: proc(op: u8) -> int {
	switch op {
	case 'M', 'm', 'L', 'l', 'T', 't': return 2
	case 'H', 'h', 'V', 'v':           return 1
	case 'C', 'c':                     return 6
	case 'S', 's', 'Q', 'q':           return 4
	case 'A', 'a':                     return 7
	}
	return 0
}

@(private)
is_path_command :: proc(c: u8) -> bool {
	switch c {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z':
		return true
	}
	return false
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// Whitespace plus, when allowed, a single comma.
@(private)
skip_separators :: proc(s: string, pos: int, allow_comma: bool) -> (next: int, comma: bool) {
	i := pos
	for i < len(s) && is_space(s[i]) do i += 1
	if allow_comma && i < len(s) && s[i] == ',' {
		comma = true
		i += 1
		for i < len(s) && is_space(s[i]) do i += 1
	}
	return i, comma
}

@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// Returns the end of the number that starts at `pos`. Packed data such as
// "1.5.5" or "4-9" works because a second '.' or a sign ends the first number.
@(private)
scan_number :: proc(s: string, pos: int) -> (end: int, ok: bool) {
	i := pos
	if i < len(s) && (s[i] == '+' || s[i] == '-') do i += 1

	digits_start := i
	for i < len(s) && is_digit(s[i]) do i += 1
	digits := i - digits_start

	if i < len(s) && s[i] == '.' {
		i += 1
		frac_start := i
		for i < len(s) && is_digit(s[i]) do i += 1
		digits += i - frac_start
	}
	if digits == 0 do return pos, false

	// An 'e' without exponent digits is left in place for the caller to reject.
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') do j += 1
		exp_start := j
		for j < len(s) && is_digit(s[j]) do j += 1
		if j > exp_start do i = j
	}
	return i, true
}

@(private)
read_number :: proc(s: string, pos: int) -> (value: f64, next: int, ok: bool) {
	end := scan_number(s, pos) or_return
	value, ok = strconv.parse_f64(s[pos:end])
	return value, end, ok
}

@(private)
read_flag :: proc(s: string, pos: int) -> (value: f64, next: int, ok: bool) {
	if pos >= len(s) || (s[pos] != '0' && s[pos] != '1') do return 0, pos, false
	return f64(s[pos] - '0'), pos + 1, true
}
