@tool
extends Node
## Nonblocking, shell-free command runner. One command at a time.
signal output(text: String)
signal finished(code: int)

var pipes: Dictionary = {}
var pending := {"stdio": PackedByteArray(), "stderr": PackedByteArray()}
var release_when_done := false

func busy() -> bool:
	return not pipes.is_empty()

func start(executable: String, arguments: PackedStringArray) -> bool:
	if busy():
		return false
	pipes = OS.execute_with_pipe(executable, arguments, false)
	return busy()

func _process(_delta: float) -> void:
	if not busy():
		return
	var full_stdout := _drain("stdio")
	var full_stderr := _drain("stderr")
	if OS.is_process_running(pipes.pid) or full_stdout or full_stderr:
		return
	var code := OS.get_process_exit_code(pipes.pid)
	for stream in ["stdio", "stderr"]:
		if not pending[stream].is_empty():
			output.emit(pending[stream].get_string_from_utf8())
		pending[stream] = PackedByteArray()
		pipes[stream].close()
	pipes.clear()
	finished.emit(code)
	if release_when_done:
		print("gdzig: detached editor command finished with exit code ", code)
		queue_free()

func _drain(stream: String) -> bool:
	# Bound work per frame, drain both pipes, and decode only complete lines so
	# a UTF-8 character split across reads is not corrupted.
	for _chunk in range(8):
		var bytes: PackedByteArray = pipes[stream].get_buffer(4096)
		if bytes.is_empty():
			return false
		pending[stream].append_array(bytes)
		var data: PackedByteArray = pending[stream]
		var newline := data.rfind(10)
		if newline >= 0:
			output.emit(data.slice(0, newline + 1).get_string_from_utf8())
			pending[stream] = data.slice(newline + 1)
		elif data.size() > 65536:
			# Malformed/unbounded lines must not grow memory forever.
			output.emit("[gdzig: discarded an overlong output line]\n")
			pending[stream] = PackedByteArray()
	return true

func release() -> void:
	# Disabling the plugin must neither block the editor nor kill only the
	# wrapper while leaving its compiler child behind. Keep draining until done.
	if busy():
		release_when_done = true
	else:
		queue_free()
