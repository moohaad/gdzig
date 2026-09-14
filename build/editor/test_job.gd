extends SceneTree

func _initialize() -> void:
	print("stdout marker")
	printerr("stderr marker")
	for i in range(1500):
		print("output line ", i)
		printerr("diagnostic line ", i)
	print("last marker")
	quit(7)
