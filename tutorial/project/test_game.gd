extends SceneTree

var failures := 0
var emissions := 0

func check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _initialize() -> void:
    run.call_deferred()

func run() -> void:
    # Watchdog also covers errors that abort this function before quit().
    create_timer(15.0).timeout.connect(func(): quit(1))
    var game = load("res://Main.tscn").instantiate()
    root.add_child(game)
    await process_frame
    check(game.playing, "round started")
    var start: Vector2 = game.player
    Input.action_press("right")
    await create_timer(0.15).timeout
    Input.action_release("right")
    check(game.player.x > start.x, "input moves the player")
    game.connect("scored", func(_total): emissions += 1)
    for i in range(5):
        game.player = game.star
        await physics_frame
        await process_frame
    check(game.score == 5, "five pickups win")
    check(emissions == 5, "one scored signal per pickup")
    check(not game.playing, "win stops the round")
    check("YOU WIN" in game.get_node("Hud").text, "typed HUD updated")
    game.round_seconds = 1
    game.reset_round()
    await create_timer(1.3).timeout
    check(not game.playing and game.remaining == 0, "coroutine ends the round")
    game.queue_free()
    await process_frame
    print("Star Catcher: ", failures, " failures")
    quit(0 if failures == 0 else 1)
