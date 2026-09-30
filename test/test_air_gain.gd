extends SceneTree

const U := 0.0254
const W := 30.0 * U
const MAX_SPEED := 320.0 * U
const AIR_ACCEL := 1000.0
const TICK := 128

var _failures := 0
var _checks := 0


func _air_accelerate(vel: Vector3, wishdir: Vector3, wishspeed: float, air_accel: float, dt: float) -> Vector3:
	var c := vel.x * wishdir.x + vel.y * wishdir.y
	var addspeed := minf(wishspeed, W) - c
	if addspeed <= 0.0:
		return vel
	var g := minf(air_accel * wishspeed * dt, addspeed)
	return Vector3(vel.x + g * wishdir.x, vel.y + g * wishdir.y, vel.z)


func _predict_dv2(c: float, wishspeed: float, air_accel: float, dt: float) -> float:
	var addspeed := minf(wishspeed, W) - c
	if addspeed <= 0.0:
		return 0.0
	var budget := air_accel * wishspeed * dt
	var g := minf(budget, addspeed)
	return g * g + 2.0 * g * c


func _s2(v: Vector3) -> float:
	return v.x * v.x + v.y * v.y


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", msg)


func _check_close(actual: float, expected: float, what: String) -> void:
	var tol := 1e-6 + absf(expected) * 1e-9
	_check(absf(actual - expected) <= tol,
		"%s: got %.9f, expected %.9f" % [what, actual, expected])


func _sweep_closed_form() -> void:
	for tick in [64, 100, 128]:
		var dt := 1.0 / float(tick)
		for air_accel in [12.0, 1000.0]:
			for wishspeed in [100.0, 250.0, MAX_SPEED]:
				for spd_u in [100.0, 200.0, 320.0, 800.0, 2000.0, 3499.0]:
					var spd: float = spd_u * U
					for step in range(0, 361):
						var deg := float(step) * 0.25
						var a := deg_to_rad(deg)
						var vel := Vector3(spd * cos(a), spd * sin(a), 0.0)
						var wishdir := Vector3(1.0, 0.0, 0.0)
						var c := vel.x * wishdir.x + vel.y * wishdir.y
						var out := _air_accelerate(vel, wishdir, wishspeed, air_accel, dt)
						var actual := _s2(out) - _s2(vel)
						var expected := _predict_dv2(c, wishspeed, air_accel, dt)
						_check_close(actual, expected,
							"closed form @ tick=%d aa=%.4f ws=%.4f spd=%.4f deg=%.4f" % [tick, air_accel, wishspeed, spd_u, deg])


func _check_tickrate_independence() -> void:
	for spd_u in [100.0, 250.0, 320.0, 800.0, 2000.0]:
		var spd: float = spd_u * U
		for step in range(0, 361):
			var deg := float(step) * 0.25
			var a := deg_to_rad(deg)
			var vel := Vector3(spd * cos(a), spd * sin(a), 0.0)
			var wishdir := Vector3(1.0, 0.0, 0.0)
			var d64 := _s2(_air_accelerate(vel, wishdir, MAX_SPEED, AIR_ACCEL, 1.0 / 64.0)) - _s2(vel)
			var d128 := _s2(_air_accelerate(vel, wishdir, MAX_SPEED, AIR_ACCEL, 1.0 / 128.0)) - _s2(vel)
			_check_close(d128, d64,
				"tickrate independence @ spd=%.4f deg=%.4f" % [spd_u, deg])


func _check_reference_values() -> void:
	var ref := {100.0: 4.4031, 250.0: 1.7936, 320.0: 1.4032, 500.0: 0.8992, 800.0: 0.5623}
	for spd_u in ref.keys():
		var spd: float = spd_u
		var vel := Vector3(0.0, spd * U, 0.0)
		var wishdir := Vector3(1.0, 0.0, 0.0)
		var out := _air_accelerate(vel, wishdir, MAX_SPEED, AIR_ACCEL, 1.0 / float(TICK))
		var gained := (Vector2(out.x, out.y).length() - spd * U) / U
		_check(absf(gained - ref[spd_u]) <= 1e-4,
			"reference gain @ spd=%.4f: got %.4f u/s, expected %.4f u/s" % [spd_u, gained, ref[spd_u]])


func _check_no_gain_past_cap() -> void:
	# Assert the velocity is bit-identical, not that a length round-trips.
	# Godot's Vector3 is float32, so length() carries ~1e-7 relative error and a
	# tolerance-based check here would be testing float32, not the gain law.
	for deg in [0.0, 30.0, 60.0, 80.0, 84.0]:
		var a := deg_to_rad(deg)
		var vel := Vector3(320.0 * U * cos(a), 320.0 * U * sin(a), 0.0)
		var out := _air_accelerate(vel, Vector3(1.0, 0.0, 0.0), MAX_SPEED, AIR_ACCEL, 1.0 / float(TICK))
		_check(out == vel,
			"velocity must be untouched at %.1f deg (c=%.2f u/s >= 30)" % [deg, 320.0 * cos(a)])


func _check_vertical_untouched() -> void:
	var vel := Vector3(0.0, 320.0 * U, -5.0)
	var out := _air_accelerate(vel, Vector3(1.0, 0.0, 0.0), MAX_SPEED, AIR_ACCEL, 1.0 / float(TICK))
	_check(out.z == vel.z, "air accel must not touch velocity.z")


func _initialize() -> void:
	_sweep_closed_form()
	_check_tickrate_independence()
	_check_reference_values()
	_check_no_gain_past_cap()
	_check_vertical_untouched()

	print("air gain parity: %d checks, %d failures" % [_checks, _failures])
	if _failures > 0:
		printerr("AIR GAIN PARITY FAILED")
		quit(1)
	else:
		print("OK: gain law matches the C++ formula, and is tickrate-independent")
		quit(0)
