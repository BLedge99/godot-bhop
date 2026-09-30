extends Label

const MOVEMENT := preload("res://src/cs_movement.gd")

var player


func _ready() -> void:
	player = get_tree().get_first_node_in_group(&"player")


func _process(_dt: float) -> void:
	if player == null:
		player = get_tree().get_first_node_in_group(&"player")
		if player == null:
			text = "no player found"
			return
	var m = player.movement
	if m == null:
		return
	var speed: float = m.horizontal_speed()
	var lines := "speed    %6.2f m/s  (%4.0f u/s)\n" % [speed, speed / MOVEMENT.U]
	lines += "vertical %6.2f m/s\n" % m.velocity.y
	lines += "grounded  %-5s      stamina %5.1f\n" % [str(m.grounded).to_upper(), m.stamina]
	lines += "jumps    %3d   perfect %3d   last: %s\n" % [m.jump_count, m.perfect_count, m.last_jump]
	lines += "autohop  %s\n" % ("ON  - hold space" if player.autobunnyhopping else "OFF - you time every jump")
	lines += "bhop cap %s\n" % ("off (no air cap)" if player.enable_bunnyhopping else "on (1.1x)")
	lines += "max_speed %.0f u/s   ground clamp %s\n" % [
		player.max_speed_units, "CS:GO (hard)" if player.csgo_ground_clamp else "per-direction"]
	if player.speed_cap > 0.0:
		lines += "playtest ceiling %.1f m/s\n" % player.speed_cap
	lines += "\nWASD move   mouse look   SPACE jump\nB autohop   R bhop cap   C ground clamp   G max_speed\nENTER respawn   ESC free mouse"
	text = lines
