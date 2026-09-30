extends SceneTree

# Headless acceptance checks. Run:
#   godot --headless --path . --script res://test/test_bhop.gd
#
# Uses a flat-ground stub so the checks do not depend on scene setup.

const TICK := 1.0 / 128.0
const MOVEMENT := preload("res://src/cs_movement.gd")


class FlatGround:
	# The sim's `origin` is the FEET position, matching what the real driver
	# passes to the physics server.
	var floor_y := 0.0

	func _sweep(from: Vector3, delta: Vector3) -> Dictionary:
		if from.y + delta.y >= floor_y:
			return {"pos": from + delta, "normal": Vector3.ZERO, "hit": false}
		var t := (floor_y - from.y) / delta.y
		return {
			"pos": Vector3(from.x + delta.x * t, floor_y, from.z + delta.z * t),
			"normal": Vector3.UP,
			"hit": true,
		}


func _make(stamina := false):
	var m = MOVEMENT.new()
	m.world = FlatGround.new()
	m.stamina_enabled = stamina
	m.autobunnyhopping = true
	m.enable_bunnyhopping = true
	return m


func _settle(m) -> void:
	for _i in 20:
		m.tick(TICK, 0, Vector2.ZERO)


var _fails := 0
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		printerr("FAIL: ", msg)


func _check_close(actual: float, expected: float, tol: float, msg: String) -> void:
	_check(absf(actual - expected) <= tol,
		"%s: got %.6f, expected %.6f (tol %.4f)" % [msg, actual, expected, tol])


func test_ground_rest() -> void:
	var m = _make()
	m.reset(Vector3.ZERO)
	_settle(m)
	_check(m.grounded, "player should settle on the ground")
	_check_close(m.origin.y, 0.0, 1e-3, "resting origin.y")
	_check_close(m.velocity.y, 0.0, 1e-3, "resting velocity.y")


func test_one_tick_window() -> void:
	# A jump must NOT be processed on the tick contact happens, only the next.
	var m = _make()
	m.reset(Vector3.ZERO)
	_settle(m)
	_check(m.grounded, "precondition: grounded")

	# Fall fast so contact is unambiguous within a few ticks.
	m.velocity = Vector3(0.0, -5.0, 0.0)
	m.grounded = false
	var landed := false
	for _i in 5:
		m.tick(TICK, 0, Vector2.ZERO)
		if m.grounded:
			landed = true
			break
	_check(landed, "should land within 5 ticks")
	_check(m.jump_count == 0, "no jump should have been attempted")

	m.tick(TICK, MOVEMENT.IN_JUMP, Vector2.ZERO)
	_check(m.jump_count == 1, "jump should fire on the first grounded tick")
	_check(not m.grounded, "ground state must be cleared by the jump")
	_check(m.velocity.y > 5.0, "jump should give upward velocity")


func test_ground_strafe_exceeds_max_speed() -> void:
	# Ground strafing must be able to exceed max_speed, otherwise the movement
	# does not match the Quake/CS2 model the learning material describes.
	var m = _make()
	m.reset(Vector3.ZERO)
	m.velocity = Vector3(0.0, 0.0, -MOVEMENT.MAX_SPEED)
	var yaw := 0.0
	for _i in 1200:
		yaw += deg_to_rad(0.6)
		m.tick(TICK, MOVEMENT.IN_FORWARD | MOVEMENT.IN_MOVELEFT, Vector2(yaw, 0.0))
	var peak := m.horizontal_speed()
	var ratio := peak / MOVEMENT.MAX_SPEED
	_check(ratio > 1.01,
		"ground strafing should exceed max_speed, got %.3fx (%.1f u/s)" % [ratio, peak / MOVEMENT.U])
	_check(m.grounded, "should still be on the ground throughout")
	print("  ground strafe peak %.1f u/s (%.3fx max_speed)" % [peak / MOVEMENT.U, ratio])


func test_ground_top_speed_is_self_limiting() -> void:
	# The ground top speed is emergent, not a constant: friction and ground
	# acceleration balance at sv_accelerate * wishspeed / sv_friction. Asserting
	# the bound rather than a magic number means this still holds if the tuning
	# constants change.
	var m = _make()
	m.reset(Vector3.ZERO)
	# Start well ABOVE the bound and check it settles back down onto it.
	m.velocity = Vector3(0.0, 0.0, -MOVEMENT.MAX_SPEED * 2.0)
	var bound := MOVEMENT.ACCELERATE * MOVEMENT.MAX_SPEED / MOVEMENT.FRICTION
	var yaw := 0.0
	for _i in 3000:
		yaw += deg_to_rad(0.6)
		m.tick(TICK, MOVEMENT.IN_FORWARD | MOVEMENT.IN_MOVELEFT, Vector2(yaw, 0.0))
	var settled := m.horizontal_speed()
	_check(settled <= bound * 1.02,
		"ground speed %.1f u/s did not settle at or below the friction/accel bound %.1f u/s" % [
			settled / MOVEMENT.U, bound / MOVEMENT.U])
	_check(settled > bound * 0.6,
		"ground speed should settle near the bound, not collapse to %.1f u/s" % [settled / MOVEMENT.U])
	print("  ground bound %.1f u/s, settles at %.1f u/s" % [bound / MOVEMENT.U, settled / MOVEMENT.U])


func test_csgo_ground_clamp_mode() -> void:
	# With the source-faithful clamp on, ground speed is hard-capped.
	var m = _make()
	m.csgo_ground_clamp = true
	m.reset(Vector3.ZERO)
	m.velocity = Vector3(0.0, 0.0, -MOVEMENT.MAX_SPEED * 2.0)
	var yaw := 0.0
	for _i in 1200:
		yaw += deg_to_rad(0.6)
		m.tick(TICK, MOVEMENT.IN_FORWARD | MOVEMENT.IN_MOVELEFT, Vector2(yaw, 0.0))
	_check_close(m.horizontal_speed(), MOVEMENT.MAX_SPEED, 0.01,
		"csgo_ground_clamp should hard-cap at max_speed")


func test_jump_height() -> void:
	var m = _make()
	m.reset(Vector3.ZERO)
	_settle(m)
	var y0: float = m.origin.y
	m.tick(TICK, MOVEMENT.IN_JUMP, Vector2.ZERO)
	var apex: float = y0
	for _i in 200:
		m.tick(TICK, 0, Vector2.ZERO)
		apex = maxf(apex, m.origin.y)
	# Continuous ideal is 1.4478 m. Discrete integration at 128 tick undershoots
	# slightly, so allow 3.5%: a 10% error in jump impulse or gravity still fails.
	_check_close(apex - y0, 1.4478, 0.05, "jump apex height")


func test_no_pogo() -> void:
	# Holding jump with autobunnyhopping off must not re-jump while airborne.
	var m = _make()
	m.autobunnyhopping = false
	m.reset(Vector3.ZERO)
	_settle(m)
	m.tick(TICK, MOVEMENT.IN_JUMP, Vector2.ZERO)
	var first: int = m.jump_count
	for _i in 30:
		m.tick(TICK, MOVEMENT.IN_JUMP, Vector2.ZERO)
	_check(m.jump_count == first, "held jump must not re-jump while airborne")


func test_air_press_not_remembered() -> void:
	# A jump pressed in the air is not remembered, and blocks the next tick.
	var m = _make()
	m.reset(Vector3.ZERO)
	_settle(m)
	m.velocity = Vector3(0.0, 3.0, 0.0)
	m.grounded = false
	m.tick(TICK, MOVEMENT.IN_JUMP, Vector2.ZERO)
	_check(m.jump_count == 0, "air press must not jump")
	_check((m.old_buttons & MOVEMENT.IN_JUMP) != 0,
		"air press must set the old-buttons jump bit")
	for _i in 20:
		m.tick(TICK, 0, Vector2.ZERO)
		_check(m.jump_count == 0, "landing must not resurrect the air press")


func test_perfect_bhop_never_loses_speed() -> void:
	# The real acceptance criterion. With bunnyhopping enabled there is no air
	# speed cap, so a correctly-turned autohop GAINS speed; the invariant is that
	# it never loses any. A single grounded tick would break this.
	var m = _make()
	m.reset(Vector3.ZERO)
	m.velocity = Vector3(12.0, 0.0, 0.0)
	var yaw := 0.0
	var prev := m.horizontal_speed()
	var worst_drop := 0.0
	for i in 900:
		yaw += deg_to_rad(0.6)
		m.tick(TICK, MOVEMENT.IN_FORWARD | MOVEMENT.IN_JUMP, Vector2(yaw, 0.0))
		var hs := m.horizontal_speed()
		worst_drop = maxf(worst_drop, prev - hs)
		prev = hs
	_check(m.jump_count >= 8, "autohop should keep jumping (got %d)" % m.jump_count)
	_check(m.perfect_count == m.jump_count,
		"all jumps should be perfect (%d of %d)" % [m.perfect_count, m.jump_count])
	_check(worst_drop < 1e-3, "perfect bhop must never lose speed (worst drop %.6f m/s)" % worst_drop)
	_check(m.horizontal_speed() > 12.0, "turned autohop should gain speed")
	print("  %.2f -> %.2f m/s over %d jumps, worst per-tick drop %.6f" % [
		12.0, m.horizontal_speed(), m.jump_count, worst_drop])


func test_bhop_speed_cap() -> void:
	# With bunnyhopping disabled the 1.1x clamp applies on every jump, so speed
	# must converge to 1.1 * max_speed and stay there.
	var m = _make()
	m.enable_bunnyhopping = false
	m.reset(Vector3.ZERO)
	m.velocity = Vector3(20.0, 0.0, 0.0)
	var cap := MOVEMENT.MAX_SPEED * 1.1
	var yaw := 0.0
	var last := 0.0
	for i in 600:
		yaw += deg_to_rad(0.6)
		m.tick(TICK, MOVEMENT.IN_FORWARD | MOVEMENT.IN_JUMP, Vector2(yaw, 0.0))
		last = m.horizontal_speed()
	# The clamp is a jump-time event, not a continuous cap, so speed hovers just
	# above 1.1x and the airborne ticks add a little on top.
	_check(last > cap * 0.98 and last < cap * 1.06,
		"speed should sit at the 1.1x cap %.3f m/s, got %.3f" % [cap, last])
	print("  capped at %.3f m/s (%.0f u/s)" % [last, last / MOVEMENT.U])


func test_missed_hop_costs_speed() -> void:
	# Contrast case: never pressing jump must bleed speed via the ground clamp.
	var m = _make()
	m.reset(Vector3.ZERO)
	m.velocity = Vector3(12.0, 0.0, 0.0)
	var before := m.horizontal_speed()
	for i in 200:
		m.tick(TICK, MOVEMENT.IN_FORWARD, Vector2.ZERO)
	_check(m.jump_count == 0, "should never jump")
	_check(m.grounded, "should be resting on the ground")
	_check(m.horizontal_speed() < before * 0.7,
		"staying on the ground must bleed speed (%.2f -> %.2f)" % [before, m.horizontal_speed()])


func test_stamina_penalty() -> void:
	# Stamina must actually bite: a hard landing should reduce jump height.
	var on = _make(true)
	on.reset(Vector3.ZERO)
	_settle(on)
	on.velocity = Vector3(0.0, -7.0, 0.0)
	on.grounded = false
	for _i in 4:
		on.tick(TICK, 0, Vector2.ZERO)
	_check(on.grounded, "should have landed")
	_check(on.stamina > 0.0, "hard landing should build stamina (got %.3f)" % on.stamina)
	_check(on.max_speed < on.base_max_speed,
		"stamina should reduce max speed (%.3f vs %.3f)" % [on.max_speed, on.base_max_speed])


func _initialize() -> void:
	test_ground_rest()
	test_one_tick_window()
	test_ground_strafe_exceeds_max_speed()
	test_ground_top_speed_is_self_limiting()
	test_csgo_ground_clamp_mode()
	test_jump_height()
	test_no_pogo()
	test_air_press_not_remembered()
	test_stamina_penalty()
	test_perfect_bhop_never_loses_speed()
	test_bhop_speed_cap()
	test_missed_hop_costs_speed()

	print("bhop sim: %d checks, %d failures" % [_checks, _fails])
	if _fails > 0:
		printerr("BHOP SIM FAILED")
		quit(1)
	else:
		print("OK")
		quit(0)
