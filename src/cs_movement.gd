extends RefCounted
class_name CSMovement

# Faithful CS:GO tick movement, ported to metres. See PLAN.md sections 5 and 6.
# This class has no Node/Input dependency; collision is delegated to an injected
# object exposing _sweep(from, delta) -> {pos, normal, hit}.

const U := 0.0254

# --- geometry (metres) ---
const HULL_HALF_WIDTH := 16.0 * U
const HULL_HEIGHT := 72.0 * U
const STEP_HEIGHT := 18.0 * U

# --- motion ---
const GRAVITY := 800.0 * U
const MAX_SPEED := 320.0 * U
const ACCELERATE := 5.5
const AIR_ACCELERATE := 1000.0
const AIR_ACCEL_TARGET := 30.0 * U
const FRICTION := 5.2
const STOP_SPEED := 80.0 * U
const MAX_VELOCITY := 3500.0 * U
const JUMP_IMPULSE := 301.993377 * U
const BUNNYJUMP_MAX_SPEED_FACTOR := 1.1
const GROUND_ACCEL_SCALE := 250.0 * U

# Source charges stamina per *unit* of fall velocity but compares it against a
# unitless range, so in metres the cost constants must be divided by U to keep
# the same magnitude of penalty. Getting this wrong makes stamina a no-op.
const STAMINA_RANGE := 100.0
const STAMINA_MAX := 80.0
const STAMINA_LAND_COST := 0.050 / U
const STAMINA_JUMP_COST := 0.080 / U
const STAMINA_RECOVERY_RATE := 60.0

const VELOCITY_MODIFIER_RECOVERY_RATE := 1.0 / 2.5

const MOVE_SPEED := 400.0 * U
const GROUND_NORMAL_THRESHOLD := 0.7
const GROUND_SNAP := 0.01

# Button bits
const IN_FORWARD := 1
const IN_BACK := 2
const IN_MOVERIGHT := 4
const IN_MOVELEFT := 8
const IN_ATTACK := 16
const IN_JUMP := 32
const IN_DUCK := 64

var world = null

var origin := Vector3.ZERO
var velocity := Vector3.ZERO
var view_angles := Vector2.ZERO

var buttons := 0
var old_buttons := 0

var grounded := false
var fall_velocity := 0.0
var stamina := 0.0
var velocity_modifier := 1.0
var base_max_speed := MAX_SPEED

var enable_bunnyhopping := true
var autobunnyhopping := false
var stamina_enabled := false
var speed_cap := 0.0
var landing_penalty := 0.0

## CS:GO hard-clamps TOTAL ground speed to the weapon max speed
## (CGameMovement::WalkMove, "Additional max speed clamp to keep us from going
## faster than allowed while turning"). That makes ground strafing unable to
## exceed max_speed at all, and it is what makes a missed hop so punishing.
##
## When false, ground movement is limited only per-direction by Accelerate()
## (addspeed = wishspeed - dot(v, wishdir)) -- the Quake / CS2 model, and the
## behaviour described in the learning material. Ground strafing can then
## exceed max_speed, and the top speed is self-limiting because friction and
## ground acceleration balance at roughly sv_accelerate * wishspeed / sv_friction.
##
## See PLAN.md section 6.8.
var csgo_ground_clamp := false

var max_speed := MAX_SPEED
var last_jump := ""
var jump_count := 0
var perfect_count := 0

var _dt := 0.0
var _sweep_normal := Vector3.ZERO
var _sweep_hit := false


func reset(pos: Vector3) -> void:
	origin = pos
	velocity = Vector3.ZERO
	buttons = 0
	old_buttons = 0
	fall_velocity = 0.0
	stamina = 0.0
	velocity_modifier = 1.0
	last_jump = ""
	jump_count = 0
	perfect_count = 0
	# A player spawned resting on a surface must start grounded. Gravity alone
	# will never push it back down onto that surface, so without this probe the
	# first tick always reads airborne.
	_sweep_to(origin + Vector3.DOWN * GROUND_SNAP)
	grounded = _sweep_hit and _sweep_normal.y >= GROUND_NORMAL_THRESHOLD


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func forward() -> Vector3:
	return Vector3(-sin(view_angles.x), 0.0, -cos(view_angles.x))


func right() -> Vector3:
	return Vector3(cos(view_angles.x), 0.0, -sin(view_angles.x))


func tick(dt: float, p_buttons: int, p_view_angles: Vector2) -> void:
	_dt = dt
	buttons = p_buttons
	view_angles = p_view_angles

	_check_parameters()

	# Ground state here is the state decided at the end of the previous tick.
	# That one-tick delay is the whole CS:GO performance window.
	var was_grounded := grounded

	_start_gravity()

	if (buttons & IN_JUMP) != 0:
		_check_jump_button(was_grounded)
	else:
		old_buttons &= ~IN_JUMP

	if grounded:
		velocity.y = 0.0
		fall_velocity = 0.0
		_friction()

	_check_velocity()

	if not grounded:
		fall_velocity = maxf(0.0, -velocity.y)

	if grounded:
		_walk_move()
	else:
		_air_move()

	_categorize_position(was_grounded)

	_check_velocity()

	_finish_gravity()

	if grounded:
		velocity.y = 0.0

	if stamina_enabled:
		stamina = maxf(0.0, stamina - STAMINA_RECOVERY_RATE * dt)
	if grounded:
		velocity_modifier = minf(1.0,
			velocity_modifier + VELOCITY_MODIFIER_RECOVERY_RATE * dt)


func _check_parameters() -> void:
	max_speed = base_max_speed
	if grounded:
		max_speed *= velocity_modifier
	if stamina_enabled and stamina > 0.0:
		var s := clampf(1.0 - stamina / STAMINA_RANGE, 0.0, 1.0)
		max_speed *= s * s


func _check_jump_button(was_grounded: bool) -> void:
	if not was_grounded:
		# An air press is not remembered, and it still blocks the next tick.
		old_buttons |= IN_JUMP
		last_jump = "air"
		return
	if (old_buttons & IN_JUMP) != 0 and not autobunnyhopping:
		last_jump = "held"
		return
	if not enable_bunnyhopping:
		_prevent_bunny_jumping()

	# THE BUNNYHOP: clearing the ground state here makes the tick skip both
	# friction and the ground speed clamp, so horizontal velocity survives intact.
	grounded = false

	var speed_before := horizontal_speed()
	velocity.y += JUMP_IMPULSE
	if stamina_enabled and stamina > 0.0:
		velocity.y *= clampf(1.0 - stamina / STAMINA_RANGE, 0.0, 1.0)
	if stamina_enabled:
		stamina = clampf(stamina + STAMINA_JUMP_COST * JUMP_IMPULSE, 0.0, STAMINA_MAX)
	_finish_gravity()

	jump_count += 1
	if speed_before > base_max_speed:
		perfect_count += 1
		last_jump = "perfect"
	else:
		last_jump = "slow"
	old_buttons |= IN_JUMP


func _prevent_bunny_jumping() -> void:
	var cap := BUNNYJUMP_MAX_SPEED_FACTOR * base_max_speed
	var spd := velocity.length()
	if cap <= 0.0 or spd <= cap:
		return
	velocity *= cap / spd


func _friction() -> void:
	var speed := velocity.length()
	if speed < 0.1:
		return
	var control := maxf(speed, STOP_SPEED)
	var newspeed := maxf(speed - control * FRICTION * _dt, 0.0)
	if not is_equal_approx(newspeed, speed):
		velocity *= newspeed / speed


func _wish() -> Array:
	var f := forward()
	var r := right()
	var fmove := 0.0
	var smove := 0.0
	if (buttons & IN_FORWARD) != 0:
		fmove += MOVE_SPEED
	if (buttons & IN_BACK) != 0:
		fmove -= MOVE_SPEED
	if (buttons & IN_MOVERIGHT) != 0:
		smove += MOVE_SPEED
	if (buttons & IN_MOVELEFT) != 0:
		smove -= MOVE_SPEED
	var wishvel := f * fmove + r * smove
	wishvel.y = 0.0
	var wishspeed := wishvel.length()
	var wishdir := wishvel / wishspeed if wishspeed > 0.0 else Vector3.ZERO
	return [wishdir, wishspeed]


func _air_move() -> void:
	var w := _wish()
	var wishdir: Vector3 = w[0]
	var wishspeed: float = w[1]
	wishspeed = minf(wishspeed, max_speed)
	if wishspeed > 0.0:
		_air_accelerate(wishdir, wishspeed, AIR_ACCELERATE)
	_step_move(velocity * _dt)


func _walk_move() -> void:
	var w := _wish()
	var wishdir: Vector3 = w[0]
	var wishspeed: float = w[1]
	wishspeed = minf(wishspeed, max_speed)
	velocity.y = 0.0
	if wishspeed > 0.0:
		_accelerate(wishdir, wishspeed, ACCELERATE)
	velocity.y = 0.0
	# Only clamp total ground speed when reproducing CS:GO's WalkMove exactly.
	# Otherwise the per-direction limit inside _accelerate is the only cap, which
	# is what lets ground strafing exceed max_speed.
	if csgo_ground_clamp:
		var spd := velocity.length()
		if spd > max_speed and spd > 0.0:
			velocity *= max_speed / spd
	_step_move(velocity * _dt)


func _air_accelerate(wishdir: Vector3, wishspeed: float, accel: float) -> void:
	# The cap applies to the *target*, and g is a per-tick velocity delta, not a
	# rate. Gain per tick is therefore independent of tickrate.
	var c := velocity.dot(wishdir)
	var addspeed := minf(wishspeed, AIR_ACCEL_TARGET) - c
	if addspeed <= 0.0:
		return
	var budget := accel * wishspeed * _dt
	velocity += minf(budget, addspeed) * wishdir


func _accelerate(wishdir: Vector3, wishspeed: float, accel: float) -> void:
	var c := velocity.dot(wishdir)
	var addspeed := wishspeed - c
	if addspeed <= 0.0:
		return
	var budget := accel * _dt * maxf(GROUND_ACCEL_SCALE, wishspeed)
	velocity += minf(budget, addspeed) * wishdir


func _start_gravity() -> void:
	# Both halves of the split subtract. With the start half ADDING, the two
	# halves cancel and velocity.y never accumulates downward.
	velocity.y -= GRAVITY * _dt * 0.5


func _finish_gravity() -> void:
	velocity.y -= GRAVITY * _dt * 0.5


func _check_velocity() -> void:
	velocity.x = clampf(velocity.x, -MAX_VELOCITY, MAX_VELOCITY)
	velocity.y = clampf(velocity.y, -MAX_VELOCITY, MAX_VELOCITY)
	velocity.z = clampf(velocity.z, -MAX_VELOCITY, MAX_VELOCITY)
	if is_nan(velocity.x):
		velocity.x = 0.0
	if is_nan(velocity.y):
		velocity.y = 0.0
	if is_nan(velocity.z):
		velocity.z = 0.0
	if speed_cap > 0.0:
		var h := horizontal_speed()
		if h > speed_cap:
			var k := speed_cap / h
			velocity.x *= k
			velocity.z *= k


func _step_move(move: Vector3) -> void:
	var start_pos := origin
	var start_vel := velocity

	# Pass 1: straight to the destination.
	_sweep_to(origin + move)
	var down_pos := origin
	var down_vel := velocity
	var down_normal := _sweep_normal

	origin = start_pos
	velocity = start_vel

	# Pass 2: retry from one step-height higher.
	var up := origin + move
	up.y += STEP_HEIGHT
	_sweep_to(up)
	_try_player_move_to(origin + velocity * _dt)
	var up_pos := origin

	# Pass 3: drop back down a step and retry.
	var down := origin + move
	down.y -= STEP_HEIGHT
	_sweep_to(down)

	if _sweep_normal.y < GROUND_NORMAL_THRESHOLD:
		origin = down_pos
		velocity = down_vel
		_sweep_normal = down_normal
		_sweep_hit = down_normal != Vector3.ZERO
		return

	var up_dist := Vector2(up_pos.x - start_pos.x, up_pos.z - start_pos.z).length()
	var down_dist := Vector2(down_pos.x - start_pos.x, down_pos.z - start_pos.z).length()
	if down_dist > up_dist:
		origin = down_pos
		velocity = down_vel
	# else: origin stays at the pass-3 trace end, which is already back on the
	# floor. Only the vertical velocity is taken from the straight pass.


func _try_player_move_to(target: Vector3) -> void:
	_sweep_to(target)


func _sweep_to(target: Vector3) -> void:
	var delta := target - origin
	_sweep_normal = Vector3.ZERO
	_sweep_hit = false
	if delta.length_squared() <= 0.0:
		return
	var res: Dictionary = world._sweep(origin, delta)
	origin = res.pos
	if res.hit:
		_sweep_hit = true
		_sweep_normal = res.normal
		if _sweep_normal.y >= GROUND_NORMAL_THRESHOLD:
			var into := velocity.dot(_sweep_normal)
			if into < 0.0:
				velocity -= _sweep_normal * into
		else:
			var into2 := velocity.dot(_sweep_normal)
			if into2 < 0.0:
				velocity -= _sweep_normal * into2 * 1.05


func _categorize_position(was_grounded: bool) -> void:
	if not _sweep_hit:
		# A standing player never sweeps into the floor, so probe for a snap
		# distance when we were grounded and are not rising.
		if was_grounded and velocity.y <= 0.0:
			_sweep_to(origin + Vector3.DOWN * GROUND_SNAP)
		if not _sweep_hit:
			_set_grounded(false)
			return
	_set_grounded(true)


func _set_grounded(now: bool) -> void:
	if now and not grounded:
		_on_land()
	grounded = now


func _on_land() -> void:
	var fv := fall_velocity
	if stamina_enabled:
		stamina = clampf(stamina + STAMINA_LAND_COST * fv, 0.0, STAMINA_MAX)
	velocity_modifier = maxf(0.0, velocity_modifier - landing_penalty)
