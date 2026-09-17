@tool
extends EditorSyntaxHighlighter

# A lightweight Zig lexer for coloring. Compilation and diagnostics still come
# from Zig; this deliberately does not try to parse declarations or types.
const KEYWORDS := {
	"align": true, "allowzero": true, "and": true, "anyframe": true,
	"anytype": true, "asm": true, "async": true, "await": true,
	"break": true, "callconv": true, "catch": true, "comptime": true,
	"const": true, "continue": true, "defer": true, "else": true,
	"enum": true, "errdefer": true, "error": true, "export": true,
	"extern": true, "fn": true, "for": true, "if": true, "inline": true,
	"linksection": true, "noalias": true, "noinline": true, "nosuspend": true,
	"opaque": true, "or": true, "orelse": true, "packed": true,
	"pub": true, "resume": true, "return": true, "struct": true,
	"suspend": true, "switch": true, "test": true, "threadlocal": true,
	"try": true, "union": true, "unreachable": true, "usingnamespace": true,
	"var": true, "volatile": true, "while": true,
}
const VALUES := {
	"true": true, "false": true, "null": true, "undefined": true,
	"void": true, "bool": true, "noreturn": true, "type": true,
	"anyerror": true, "usize": true, "isize": true, "comptime_int": true,
	"comptime_float": true, "f16": true, "f32": true, "f64": true,
	"f80": true, "f128": true,
}

func _create() -> EditorSyntaxHighlighter:
	return get_script().new()

func _get_name() -> String:
	return "Zig"

func _get_supported_languages() -> PackedStringArray:
	return PackedStringArray(["zig"])

func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var edit := get_text_edit()
	if edit == null or line < 0 or line >= edit.get_line_count():
		return {}
	var source := edit.get_line(line)
	var normal := _theme_color("text_color", edit.get_theme_color("font_color"))
	var keyword := _theme_color("keyword_color", Color(0.9, 0.55, 0.9))
	var value := _theme_color("base_type_color", Color(0.5, 0.8, 0.9))
	var builtin := _theme_color("function_color", Color(0.6, 0.8, 1.0))
	var string_color := _theme_color("string_color", Color(0.9, 0.75, 0.5))
	var comment := _theme_color("comment_color", Color(0.5, 0.6, 0.5))
	var number := _theme_color("number_color", Color(0.7, 0.8, 0.5))
	var result := {0: {"color": normal}}
	var i := 0
	while i < source.length():
		var c := source.unicode_at(i)
		var next := source.unicode_at(i + 1) if i + 1 < source.length() else -1
		if c == 47 and next == 47: # // line comment
			result[i] = {"color": comment}
			break
		if c == 92 and next == 92 and source.substr(0, i).strip_edges().is_empty(): # Zig multiline string line
			result[i] = {"color": string_color}
			break
		if c == 34 or c == 39: # string or character literal
			var start := i
			i += 1
			while i < source.length():
				var item := source.unicode_at(i)
				if item == 92:
					i += 2
					continue
				i += 1
				if item == c:
					break
			result[start] = {"color": string_color}
			result[mini(i, source.length())] = {"color": normal}
			continue
		if c == 64 and _identifier_start(next): # @builtin
			var start := i
			i += 2
			while i < source.length() and _identifier_continue(source.unicode_at(i)):
				i += 1
			result[start] = {"color": builtin}
			result[i] = {"color": normal}
			continue
		if c >= 48 and c <= 57:
			var start := i
			i += 1
			while i < source.length():
				var digit := source.unicode_at(i)
				if not (_identifier_continue(digit) or digit == 46):
					break
				i += 1
			result[start] = {"color": number}
			result[i] = {"color": normal}
			continue
		if _identifier_start(c):
			var start := i
			i += 1
			while i < source.length() and _identifier_continue(source.unicode_at(i)):
				i += 1
			var word := source.substr(start, i - start)
			if KEYWORDS.has(word):
				result[start] = {"color": keyword}
				result[i] = {"color": normal}
			elif VALUES.has(word) or (word.length() > 1 and (word.begins_with("u") or word.begins_with("i")) and word.substr(1).is_valid_int()):
				result[start] = {"color": value}
				result[i] = {"color": normal}
			continue
		i += 1
	return result

func _identifier_start(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95

func _identifier_continue(c: int) -> bool:
	return _identifier_start(c) or (c >= 48 and c <= 57)

func _theme_color(key: String, fallback: Color) -> Color:
	var settings := EditorInterface.get_editor_settings()
	var path := "text_editor/theme/highlighting/" + key
	return settings.get_setting(path) if settings.has_setting(path) else fallback
