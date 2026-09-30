extends Node3D
class_name BhopPlayer

# Drives CSMovement from _physics_process. Deliberately NOT a CharacterBody3D:
# the movement sim needs to own floor state, and move_and_slide rewrites
# velocity in ways that destroy the perfect-bhop invariant. See PLAN.md 7.3.
#
# CSMovement is reached through an explicit preload rather than the global
# `class_name` registry. The registry lives in .godot/, which is a build
# artifact and is gitignored, so a fresh checkout without an import pass would
# fail to parse every script that names the class.

const MOVEMENT := preload("res://src/cs_movement.gd")

@export_group("Movement")
@export var forward_key: Key = KEY_W
@export var back_key: Key = KEY_S
@export var left_key: Key = KEY_A
@export var right_key: Key = KEY_D
@export var jump_key: Key = KEY_SPACE
@export_range(0.01, 10.0, 0.01) var mouse_sensitivity := 1.0
@export_range(0.001, 0.1, 0.001) var m_yaw := 0.022
@export_range(0.001, 0.1, 0.001) var m_pitch := 0.022
var jump_mode := "auto"
var _scroll_jump := false

@export_group("Bhop")
## When on, holding jump re-jumps on every landing (CS:GO sv_autobunnyhopping).
@export var autobunnyhopping := true
## When off, every jump clamps speed to 1.1x max_speed (sv_enablebunnyhopping).
@export var enable_bunnyhopping := true
## Ground speed limit in u/s. 320 is the CS:GO sv_maxpeed from the movement
## source; 260 is the CS2 value. The ground strafe equilibrium scales with it.
@export var max_speed_units := 320.0
## Ground movement is normally capped only per-direction, so strafing on the
## ground can exceed max_speed (Quake / CS2 model). Turn this on for CS:GO's
## hard total-speed clamp, which forbids that but punishes missed hops harder.
@export var csgo_ground_clamp := false
## CS:GO's landing penalty. Shipped default is 80, which is far too punishing
## for a bhop server, so it defaults to off.
@export var stamina_enabled := false
## Optional playtest ceiling in m/s. 0 = uncapped, which is what a bhop server
## with sv_enablebunnyhopping 1 actually gives you.
@export var speed_cap := 0.0

@export_group("Keys")
@export var toggle_autohop_key: Key = KEY_B
@export var toggle_cap_key: Key = KEY_R
@export var toggle_ground_clamp_key: Key = KEY_C
@export var toggle_max_speed_key: Key = KEY_G
@export var reset_key: Key = KEY_ENTER

@export_group("Spawn")
@export var spawn_position := Vector3(0.0, 0.05, 0.0)
@export var spawn_speed := 0.0
@export var spawn_yaw := 0.0

@export_group("Debug")
@export var print_ticks := false

var movement
var view_angles := Vector2.ZERO

var _hull: BoxShape3D
var _hull_offset := Vector3(0.0, MOVEMENT.HULL_HEIGHT * 0.5, 0.0)


func _ready() -> void:
	add_to_group(&"player")

	_hull = BoxShape3D.new()
	_hull.size = Vector3(MOVEMENT.HULL_HALF_WIDTH * 2.0, MOVEMENT.HULL_HEIGHT,
			MOVEMENT.HULL_HALF_WIDTH * 2.0)
	var shape_node := CollisionShape3D.new()
	shape_node.shape = _hull
	shape_node.position = _hull_offset
	add_child(shape_node)

	movement = MOVEMENT.new()
	movement.world = self
	movement.autobunnyhopping = autobunnyhopping
	movement.enable_bunnyhopping = enable_bunnyhopping
	movement.stamina_enabled = stamina_enabled
	movement.speed_cap = speed_cap
	movement.csgo_ground_clamp = csgo_ground_clamp
	movement.base_max_speed = max_speed_units * MOVEMENT.U
	movement.reset(spawn_position)
	movement.velocity = Vector3(0.0, 0.0, -spawn_speed)
	view_angles = Vector2(spawn_yaw, 0.0)

	position = movement.origin
	rotation = Vector3(0.0, spawn_yaw, 0.0)
	$Camera3D.rotation.x = 0.0
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	Input.use_accumulated_input = false


func respawn() -> void:
	movement.reset(spawn_position)
	movement.velocity = Vector3(0.0, 0.0, -spawn_speed)
	view_angles = Vector2(spawn_yaw, 0.0)
	position = movement.origin
	rotation = Vector3(0.0, spawn_yaw, 0.0)
	$Camera3D.rotation.x = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			view_angles.x -= deg_to_rad(event.relative.x * mouse_sensitivity * m_yaw)
			view_angles.y = clampf(view_angles.y - deg_to_rad(event.relative.y * mouse_sensitivity * m_pitch),
				-PI * 0.49, PI * 0.49)
			rotation = Vector3(0.0, view_angles.x, 0.0)
			$Camera3D.rotation.x = view_angles.y
		return
	if event is InputEventMouseButton and event.pressed and jump_mode == "scroll":
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_jump = true
			return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				var menu = get_tree().get_first_node_in_group(&"settings_menu")
				if menu != null:
					menu.toggle()
			toggle_autohop_key:
				autobunnyhopping = not autobunnyhopping
				movement.autobunnyhopping = autobunnyhopping
			toggle_cap_key:
				enable_bunnyhopping = not enable_bunnyhopping
				movement.enable_bunnyhopping = enable_bunnyhopping
			toggle_ground_clamp_key:
				csgo_ground_clamp = not csgo_ground_clamp
				movement.csgo_ground_clamp = csgo_ground_clamp
			toggle_max_speed_key:
				max_speed_units = 320.0 if max_speed_units > 300.0 else 260.0
				movement.base_max_speed = max_speed_units * MOVEMENT.U
			reset_key:
				respawn()


func _sample_buttons() -> int:
	var b := 0
	var settings_menu = get_tree().get_first_node_in_group(&"settings_menu")
	if settings_menu != null and settings_menu.panel.visible:
		_scroll_jump = false
		return 0
	if Input.is_physical_key_pressed(forward_key):
		b |= MOVEMENT.IN_FORWARD
	if Input.is_physical_key_pressed(back_key):
		b |= MOVEMENT.IN_BACK
	if Input.is_physical_key_pressed(right_key):
		b |= MOVEMENT.IN_MOVERIGHT
	if Input.is_physical_key_pressed(left_key):
		b |= MOVEMENT.IN_MOVELEFT
	if jump_mode == "auto" and Input.is_physical_key_pressed(jump_key):
		b |= MOVEMENT.IN_JUMP
	if _scroll_jump:
		b |= MOVEMENT.IN_JUMP
		_scroll_jump = false
	return b


func _physics_process(_delta: float) -> void:
	# One sample per tick: this single sample IS the CS:GO input packet.
	# Do not buffer input across ticks; that reproduces CS2 behaviour instead.
	var buttons := _sample_buttons()
	movement.tick(1.0 / float(Engine.physics_ticks_per_second), buttons,
		Vector2(view_angles.x, 0.0))
	position = movement.origin
	if print_ticks:
		print("grounded=%s speed=%.3f last_jump=%s" % [
			movement.grounded, movement.horizontal_speed(), movement.last_jump])


# Collision provider for CSMovement: a box sweep through the physics server, so
# the sim itself stays free of Node dependencies. `from` is the FEET position.
func _sweep(from: Vector3, delta: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state

	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _hull
	q.collision_mask = 0xFFFFFFFF
	q.margin = 0.0
	q.transform = Transform3D(Basis(), from + delta + _hull_offset)
	if space.intersect_shape(q, 1).is_empty():
		return {"pos": from + delta, "normal": Vector3.ZERO, "hit": false}

	# Binary search the largest clear fraction. Deterministic and cheap; avoids
	# depending on cast_motion's safe/unsafe split behaviour.
	var lo := 0.0
	var hi := 1.0
	for _i in 12:
		var mid := (lo + hi) * 0.5
		q.transform = Transform3D(Basis(), from + delta * mid + _hull_offset)
		if space.intersect_shape(q, 1).is_empty():
			lo = mid
		else:
			hi = mid

	# intersect_shape() returns no normal in Godot 4, so read the contact normal
	# with get_rest_info(). It needs real overlap, so query at `hi`, the first
	# blocked fraction; `lo` is clear by construction.
	var q2 := PhysicsShapeQueryParameters3D.new()
	q2.shape = _hull
	q2.collision_mask = 0xFFFFFFFF
	q2.margin = 0.0
	q2.transform = Transform3D(Basis(), from + delta * hi + _hull_offset)
	var info := space.get_rest_info(q2)
	var normal: Vector3 = info.normal if info.has("normal") else Vector3.ZERO
	return {"pos": from + delta * lo, "normal": normal, "hit": true}
