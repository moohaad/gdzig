@tool
extends RefCounted

static func parse(line: String, root: String) -> Dictionary:
	var ansi := RegEx.new()
	ansi.compile("\\x1b\\[[0-9;]*[A-Za-z]")
	line = ansi.sub(line, "", true).strip_edges()
	var pattern := RegEx.new()
	pattern.compile("^(.+\\.zig):([0-9]+):([0-9]+): (error|warning|note): (.*)$")
	var match_result := pattern.search(line)
	if match_result == null:
		return {}
	var path := match_result.get_string(1).replace("\\", "/")
	if not path.is_absolute_path():
		path = root.path_join(path)
	var row := int(match_result.get_string(2))
	var column := int(match_result.get_string(3))
	if row < 1 or column < 1:
		return {}
	return {"path": path.simplify_path(), "line": row, "column": column,
		"severity": match_result.get_string(4), "message": match_result.get_string(5)}
