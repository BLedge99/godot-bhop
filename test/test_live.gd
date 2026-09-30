extends SceneTree

# Drives the real BhopPlayer against real Godot physics in a live scene, so the
# driver, the box sweep and the scene are all exercised. Run:
#   godot --headless --path . --script res://test/test_live.gd

const DT := 1.0 / 128.0
const MOVEMENT := preload("res://src/cs_movement.gd")

var _fails := 0
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
	var packed: PackedScene = load("res://main.tscn")
	_check(packed != null, "main.tscn should load")
	if packed == null:
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await physics_frame

	var player = scene.get_node_or_null("Player")
	_check(player != null, "scene should contain a BhopPlayer")
	if player == null:
		quit(1)
		return
	var m = player.movement
	_check(m != null, "player should have built its movement sim")
	_check(m.grounded, "player should be resting on the floor on spawn")

	# Let it settle for a second of ticks.
	for _i in 128:
		m.tick(DT, 0, Vector2.ZERO)
		player.position = m.origin
	_check(m.grounded, "should still be grounded after settling")
	_check(absf(m.origin.y) < 0.02, "should rest on the floor, y=%.4f" % m.origin.y)
	print("  rest: y=%.5f  grounded=%s" % [m.origin.y, m.grounded])

	# A real jump must leave the floor and come back.
	var y0: float = m.origin.y
	m.tick(DT, MOVEMENT.IN_JUMP, Vector2.ZERO)
	player.position = m.origin
	var apex: float = y0
	for _i in 200:
		m.tick(DT, 0, Vector2.ZERO)
		player.position = m.origin
		apex = maxf(apex, m.origin.y)
	_check(apex - y0 > 1.3 and apex - y0 < 1.6,
		"jump apex in live scene should be ~1.45 m, got %.3f" % (apex - y0))
	_check(m.grounded, "should land again")
	print("  jump apex: %.3f m, landed=%s" % [apex - y0, m.grounded])

	# Full autohop run through real physics: must never lose speed.
	m.reset(Vector3(0.0, 0.05, 0.0))
	m.velocity = Vector3(0.0, 0.0, -12.0)
	m.autobunnyhopping = true
	var yaw := 0.0
	var prev: float = m.horizontal_speed()
	var worst_drop := 0.0
	for i in 900:
		yaw += deg_to_rad(0.6)
		m.tick(DT, MOVEMENT.IN_FORWARD | MOVEMENT.IN_JUMP, Vector2(yaw, 0.0))
		player.position = m.origin
		var hs: float = m.horizontal_speed()
		worst_drop = maxf(worst_drop, prev - hs)
		prev = hs
	_check(m.jump_count >= 8, "autohop should keep jumping (got %d)" % m.jump_count)
	_check(m.perfect_count == m.jump_count,
		"all jumps perfect (%d of %d)" % [m.perfect_count, m.jump_count])
	_check(worst_drop < 0.05, "no speed loss in live scene (worst %.4f)" % worst_drop)
	print("  live autohop: 12.00 -> %.2f m/s over %d jumps, worst drop %.4f" % [
		m.horizontal_speed(), m.jump_count, worst_drop])

	test_ground_strafe_live(player, m)
	test_scene_setup(scene, player)

	print("live scene: %d checks, %d failures" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


# A render cannot be captured headlessly, so assert the scene graph and the
# resources the renderer would need are actually wired up.
func test_scene_setup(scene: Node, player: Node) -> void:
	var env := scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_check(env != null, "scene should have a WorldEnvironment")
	if env != null:
		var e := env.environment
		_check(e != null, "WorldEnvironment should have an Environment")
		_check(e.background_mode == Environment.BG_SKY, "background should be the sky")
		_check(e.sky != null and e.sky.sky_material != null, "sky should have a material")
		_check(e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY,
			"ambient should come from the sky")
		_check(e.ambient_light_energy > 0.0, "ambient energy should be non-zero")

	var sun := scene.get_node_or_null("Sun") as DirectionalLight3D
	_check(sun != null, "scene should have a DirectionalLight3D")
	if sun != null:
		# Light travels along -Z of its basis; it must point downward.
		_check(-sun.global_transform.basis.z.y > 0.5,
			"sun should point downward (dir.y=%.3f)" % -sun.global_transform.basis.z.y)

	var floor_body := scene.get_node_or_null("Floor") as StaticBody3D
	_check(floor_body != null, "scene should have a floor body")
	if floor_body != null:
		var shape := floor_body.get_node_or_null("Shape") as CollisionShape3D
		_check(shape != null and shape.shape != null, "floor should have a collision shape")
		_check(shape.shape is BoxShape3D, "floor collision should be a box")
		var visual := floor_body.get_node_or_null("Visual") as MeshInstance3D
		_check(visual != null and visual.mesh != null, "floor should have a visible mesh")
		if visual != null:
			var mat := visual.material_override as StandardMaterial3D
			_check(mat != null, "floor should override its material")
			if mat != null:
				_check(mat.albedo_texture != null,
					"floor needs a checker texture or you cannot perceive speed")
				var uv: Vector3 = mat.uv1_scale
				_check(uv.x > 1.0 and uv.y > 1.0,
					"checker must tile across the floor (uv1_scale=%.2f,%.2f)" % [uv.x, uv.y])

	var markers := scene.get_node_or_null("Markers")
	_check(markers != null, "scene should have distance markers to judge speed")

	var cam := player.get_node_or_null("Camera3D") as Camera3D
	_check(cam != null, "player should have a Camera3D")
	if cam != null:
		_check(cam.current, "player camera should be the active camera")
		# Eye height 64 u = 1.6256 m above the feet.
		_check(cam.position.y > 1.5 and cam.position.y < 1.7,
			"eye height should be ~1.6256 m, got %.4f" % cam.position.y)
		_check(cam.fov > 90.0, "CS-like FOV expected, got %.1f" % cam.fov)

	var label := scene.get_node_or_null("Hud/Label") as Label
	_check(label != null, "scene should have a HUD label")
	if label != null:
		await process_frame
		_check(label.text != "" and label.text != "loading", "HUD should be showing telemetry")
		_check(label.text.contains("speed"), "HUD should report speed")
		_check(label.text.contains("autohop"), "HUD should report the mode")


# Ground strafing through the real physics server, with no jumping at all.
func test_ground_strafe_live(player: Node, m) -> void:
	m.reset(Vector3(0.0, 0.05, 0.0))
	m.velocity = Vector3(0.0, 0.0, -MOVEMENT.MAX_SPEED)
	var yaw := 0.0
	for _i in 1200:
		yaw += deg_to_rad(0.6)
		m.tick(DT, MOVEMENT.IN_FORWARD | MOVEMENT.IN_MOVELEFT, Vector2(yaw, 0.0))
		player.position = m.origin
	var top: float = m.horizontal_speed()
	_check(m.jump_count == 0, "ground strafe test must not jump")
	_check(m.grounded, "must stay grounded throughout")
	_check(top > MOVEMENT.MAX_SPEED * 1.01,
		"live ground strafe should exceed max_speed, got %.1f u/s (%.3fx)" % [
			top / MOVEMENT.U, top / MOVEMENT.MAX_SPEED])
	print("  live ground strafe: %.1f u/s (%.3fx max_speed), jumps %d" % [
		top / MOVEMENT.U, top / MOVEMENT.MAX_SPEED, m.jump_count])
