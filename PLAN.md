# Bunnyhop Movement Controller for Godot 4 — Implementation Plan

Status: researched, ready to build. Every constant below was read out of the CS:GO
movement source (see [Source Material](#source-material)); none are guessed.

---

## 1. Objective

Build a first-person bunnyhop movement controller in **Godot 4.x / GDScript** that
reproduces CS:GO's tick-based movement faithfully enough that a player can
bunnyhop at the same speed and with the same timing windows as in the real game,
and add an auto-hop mode in which **holding jump emits a perfectly-timed jump
press** on the player's behalf.

The deliverable is a movement simulation, not a game. There is no level, no
HUD, no networking, no art.

### Definition of done

A player dropped onto flat ground, holding forward and turning, reaches the
bhop cap and then **never loses horizontal speed again**, no matter how many
hops. A single tick spent on the ground costs speed. A jump pressed on the
wrong tick costs speed. These are observable, testable, and are the whole point.

Measured: **worst per-tick speed drop 0.000000 m/s across 900 ticks and 10
jumps**, with all 10 jumps classified perfect. See §9.1.

> Note on the original wording. The first draft of this plan said speed should be
> *flat*. That is only true with `sv_enablebunnyhopping = 0`, where the 1.1×
> clamp pins it. With bunnyhopping **enabled** — the bhop-server configuration,
> and what is actually implemented — there is no cap on air speed at all, and a
> correctly turned player keeps gaining until their turning cannot keep up. The
> cap-agnostic invariant is "never loses speed", and that is what is now tested.

---

## 2. Locked decisions

Decided with the user. Do not revisit without asking.

| Decision | Value | Why |
|---|---|---|
| Engine | Godot 4.x | |
| Language | GDScript | |
| Simulation model | **Faithful CS:GO tick model only** | CS2 subtick bugs are explicitly out of scope |
| Units | **Godot metres throughout** | Convert Source units at the constant table, once |
| Perspective | 3D, first person, yaw-only view | |
| Modes | `MANUAL` (no assistance) and `AUTO` (hold jump = perfect press) | |
| Auto-strafe | **None.** No automatic turning, no automatic A/D. | |
| Auto key-change sync | **None.** The sim never synthesises strafe input. | |
| Networking | Out of scope | |

### Explicitly not doing

Auto-strafing is out of scope *by request*, and it is also the right call on the
merits: the physics in §6 give correct gains only if the human turns. A
controller that faked it would be hiding the thing the simulation exists to model.

---

## 3. Source material

> **The two PDFs are gitignored and are not in the repository.** They are
> third-party reference documents — one of them a re-upload of someone else's
> blog post — so they are inputs to this project, not part of it, and ~1.2 MB of
> copyrighted material has no business in permanent history. This section
> records what each one contains so the knowledge is not lost with the binaries.
> Everything the implementation needs that came from them has already been
> restated in §5 and §6, so the project can be worked on without them at all.

### 3.1 Reference documents (local copies, gitignored)

**`bunnyhopping-in-cs2.pdf`** (22 pp) — reverse-engineering of the *CS2* movement
code. Used here for:

- the taxonomy of jump outcomes (perfect / buffered / restored / deferred) and
  the definition of a *perfect* bhop: a jump that fires before ground movement
  has run since landing;
- the formal statement that on_ground is decided at the end of tick N and
  consumed at the start of tick N+1, which makes the CS:GO performance window
  exactly one tick;
- the jump cooldown rules — a press needs one full tick with no jump input
  before it counts again;
- the fact that a press made **in the air is not remembered** and additionally
  poisons the next tick;
- Appendix A.2's closed-form performance numbers, usable as a sanity check.

CS2-specific behaviour (subtick splitting, the 2-unit hover ground check, the
1/64-tick press-time rounding lottery, crouchbugs, jumpbugs) is **out of scope**.

**`Strafing Theory by injx.pdf`** — Quake 3 air acceleration. Used for the
*reasoning* about air control, re-derived into CS terms in §6.3. Note the
formulation differs from CS: Quake caps the velocity *component in the
acceleration direction* at `g_speed`; CS caps the *wish speed* at 30 u/s. Same
phenomenon, different parameterisation. Do not port Quake's numbers directly.

### 3.2 The CS:GO movement source

Repository: `github.com/lua9520/source-engine-2018-cstrike15_src`

| File | What was taken from it |
|---|---|
| `game/shared/movevars_shared.cpp` | All base movement cvar defaults |
| `game/shared/cstrike15/cs_gamemovement.cpp` | `CheckJumpButton`, `PreventBunnyJumping`, `PlayerMove`, `CheckParameters`, `OnJump`, `OnLand`, `Accelerate`, all CS-specific cvars |
| `game/shared/gamemovement.cpp` | `FullWalkMove` (tick order), `Friction`, `Accelerate`, `AirAccelerate`, `AirMove`, `WalkMove`, `CheckVelocity`, `StartGravity`, `FinishGravity`, `StepMove`, `TryPlayerMove`, `ClipVelocity`, `CategorizePosition`, `SetGroundEntity` |

**Usage note for agents:** treat this as a *specification to reimplement*, not a
source to transliterate. Reimplement the algorithm; do not paste the code. The
plan below restates every behaviour you need in prose and formulas, so the
source should only be consulted to resolve a genuine ambiguity in this document.

---

## 4. Unit system

Source works in "units" where **1 unit = 1 inch = 0.0254 m exactly**. This
project works in **metres**.

> **The conversion only applies to distances and velocities. Every per-second
> constant (friction, acceleration rates, timers, multipliers) carries over
> numerically unchanged.** An agent that "converts" `sv_accelerate = 5.5` into
> something else has introduced a bug.

Define once, in a single constants file, and never inline a magic number.

```
const U := 0.0254                  # Source units per metre
```

### Precision

**Keep Godot's default 32-bit `float`.** `Vector3` and `float` in GDScript are
single-precision unless you build the double-precision editor, and Source's
`Vector` and `float` are 32-bit too. Matching the engine's precision matches the
reference implementation, which is the point of the exercise.

The practical consequence is that any assertion about a *measured length* has
roughly 1e-7 relative error and must be asserted with a tolerance, while any
assertion about a *component* can be exact. In `test_air_gain.gd` the "no gain
past the cap" check therefore compares the velocity component-wise for exact
equality rather than comparing lengths, because the length round-trip was
measuring float32 rather than the gain law. A 1e-12 tolerance there was
unsatisfiable and was testing the wrong thing.

---

## 5. Constant reference

Provenance column gives the file each value came from. Everything is a **shipped
default from this repository**, not necessarily what a live competitive server
runs — see [Open Question 1](#open-question-1).

### 5.1 Geometry

| Quantity | Source value | Metres | Provenance |
|---|---|---|---|
| Unit scale | 1 u | 0.0254 m | definition |
| Hull min | (-16, -16, 0) | (-0.4064, -0.4064, 0) | `gamerules.cpp` |
| Hull max | (16, 16, 72) | (0.4064, 0.4064, 1.8288) | `gamerules.cpp` |
| Eye height | 64 u | 1.6256 m | CS convention |
| Step height | 18 u (`sv_stepsize`) | 0.4572 m | `movevars_shared.cpp` |
| Crouch height | 36 u | 0.9144 m | CS convention |

The hull is a **32 × 32 × 72 axis-aligned box with its origin at the feet**. Use
a `BoxShape3D` of 0.8128 × 0.8128 × 1.8288 m, positioned so the box centre sits
1.8288 / 2 = 0.9144 m above the origin. A capsule is a different shape and will
behave differently in corners — do not substitute one.

### 5.2 Motion constants (per-second — DO NOT CONVERT)

| Constant | Value | Meaning |
|---|---|---|
| `sv_gravity` | **800** | gravity, u/s² → **20.32 m/s²** (this one *is* a distance rate) |
| `sv_accelerate` | **5.5** | ground acceleration |
| `sv_airaccelerate` | **1000** | air acceleration — **bhop server value**, see §5.6 |
| `sv_friction` | **5.2** | ground friction |
| `sv_stopspeed` | **80** u/s = 2.032 m/s | friction floor |
| `sv_maxspeed` | **320** u/s = 8.128 m/s | max speed, wish-speed clamp |
| air accel target cap | **30** u/s = 0.762 m/s | hardcoded in air acceleration |
| `sv_maxvelocity` | **3500** u/s = 88.9 m/s | per-axis sanity clamp |
| `sv_jump_impulse` | **301.993377** u/s = **7.67063 m/s** | upward velocity on jump |
| jump apex | 57.0 u | **1.4478 m** |
| `BUNNYJUMP_MAX_SPEED_FACTOR` | **1.1** | → cap 352 u/s = **8.9408 m/s** |

The air accel target cap is hardcoded (not a cvar) in the source at 30 u/s, so it
is 0.762 m/s on every bhop server regardless of how the cvars are set.

### 5.3 Stamina (CS:GO's landing penalty — *not* optional)

| Constant | Value |
|---|---|
| `STAMINA_RANGE` | 100.0 |
| `sv_staminamax` | 80 |
| `sv_staminalandcost` | 0.050 (per unit of fall velocity) |
| `sv_staminajumpcost` | 0.080 (per unit of jump impulse) |
| `sv_staminarecoveryrate` | 60 units/s |

### 5.4 Mode cvars

| Constant | Default | Meaning |
|---|---|---|
| `sv_enablebunnyhopping` | 0 | when 0, speed is clamped to 1.1 × max speed on jump |
| `sv_autobunnyhopping` | 0 | when 1, holding jump keeps re-jumping |
| velocity-modifier recovery | 1/2.5 per second | recovers **only while grounded** |

### 5.5 Timing

**Chosen: 128 tick** (15.625 ms → 7.8125 ms per tick). See §5.6 for the decision.

| Quantity | 64 tick | 128 tick |
|---|---|---|
| Tick length | 1/64 s = 15.625 ms | **1/128 s = 7.8125 ms** |

Set `physics_ticks_per_second = 128` in `project.godot`. One Godot physics tick
is then exactly one CS tick, and the performance window is 7.8125 ms.

### 5.6 Why 128 tick, and what airaccelerate = 1000 actually does

#### The tickrate decision

**102.4 is not a server tickrate and should not be used here.** CS:GO server
tickrates are integers (64 / 100 / 128). 102.4 is the *updaterate* — the rate at
which the server accepts client input commands, a separate quantity that affects
input delivery latency rather than the simulation step. In Source 1 the movement
simulation runs at the tickrate regardless, and the button state is not
timestamped within the tick, so the updaterate cannot create or widen a bhop
window.

> I could not verify the 102.4 updaterate default in this repository — those
> cvars are engine-side and absent from the `game/` tree. Treat the explanation
> above as strong prior knowledge, not source-verified. It does not affect the
> decision, which rests on the next point.

The decision is forced anyway, on arithmetic grounds:

- **1/102.4 is not exactly representable in binary floating point.** 102.4 is
  2¹⁰/10, not a dyadic rational, so every tick boundary would carry
  representation error that accumulates through the gravity and acceleration
  integration. For a simulation whose entire purpose is timing parity, that is
  disqualifying.
- **1/128 = 0.0078125 = 2⁻⁷ is exactly representable.** Zero drift, always.
- Godot's `physics_ticks_per_second` is an integer property; 102.4 cannot be
  expressed at all.
- 128 is a real CS:GO server tickrate and the bhop/surf community default.

The one real cost is that the bhop window halves to 7.8125 ms, which makes
`MANUAL` mode harder. `AUTO` mode is unaffected — it is tick-exact by
construction.

#### What airaccelerate = 1000 does — and does not — change

The acceleration budget is `airaccel × wishspeed × dt`, and it competes with
`addspeed = 30 − c` (where `c` is the velocity component along the wish
direction). A naive reading says 1000 is a huge number that changes everything.
**In the bhop regime it changes nothing at all.** Verified numerically over
155,628 cases (max absolute error in Δ|v|² of 3.7 × 10⁻⁹, i.e. float64
cancellation in the differencing, not model error):

| tick | airaccel | budget | Budget binds only when |
|---|---|---|---|
| 64 | 12 | 60.0 u/s | never, for all `c < 30` |
| 64 | **1000** | 5000.0 u/s | never |
| 128 | 12 | 30.0 u/s | `c < 0` — **already diverging** |
| 128 | **1000** | 2500.0 u/s | never |

The budget only binds when `c < 30 − airaccel × wishspeed × dt`. Normal bhop
strafing sits at `c ≈ 0` (wish direction ~90° from velocity), where all four
rows agree exactly.

Where they *do* diverge is when the wish direction points **away** from
velocity, past ~96° at 64 tick:

| wishdir vs velocity | airaccel 12 | airaccel 1000 |
|---|---|---|
| 85° | +0.1908 u/s | +0.1908 u/s — identical |
| 90° | +1.4032 u/s | +1.4032 u/s — identical |
| 96° | −0.6474 u/s | −0.3421 u/s — differ |
| 180° | −60.00 u/s | −290.00 u/s — differ |

**Conclusion:** 1000 is a no-op for gaining speed and a correctness improvement
for strafing into reverse. It is also the reason to prefer 128 tick over 64: at
128 tick, airaccel 12 sits exactly on the divergence boundary, so the 1000
setting removes an entire class of tickrate-dependent edge behaviour. Use 1000.


---

## 6. Core mechanics

This section is the actual design. Read it before writing code.

### 6.1 The perfect bhop, in one sentence

The jump handler **clears the ground entity before the ground-movement branch is
evaluated**, so the branch that would apply friction and clamp speed never runs
that tick, and the player moves with air movement instead — which only ever
*adds* velocity.

Everything else follows from getting that ordering right.

### 6.2 Tick order

Per tick, in this exact order. Order is load-bearing.

```
 1. sample input              → buttons for this tick only
 2. CheckParameters           → compute this tick's max speed (stamina, modifiers)
 3. CategorizePosition        → is the player on the ground? (decided LAST tick)
 4. StartGravity              → half a tick of gravity, upward
 5. jump check:
      if jump pressed this tick → CheckJumpButton()
      else                      → clear the old-buttons jump bit
 6. if grounded:
        velocity.z = 0
        fall_velocity = 0
        Friction()
 7. CheckVelocity             → clamp each axis to ±max_velocity, zero NaNs
 8. if grounded: WalkMove()   → ground accel + hard clamp to max speed
    else:          AirMove()  → air accel only
 9. CategorizePosition        → re-evaluate ground, fire OnLand
10. CheckVelocity
11. FinishGravity             → half a tick of gravity, downward
12. if grounded: velocity.z = 0
13. CheckFalling              → (skip; fall damage out of scope)
```

Steps 4 and 11 together give one full tick of gravity, applied half before and
half after the move. This is a standard semi-implicit Euler split and matters for
trajectory parity.

### 6.3 The three movement paths

#### Friction (ground only)

```
speed   = length(velocity)
if speed < 0.1: return
control = max(speed, stopspeed)          # 80 u/s floor
drop    = control * friction * dt        # friction = 5.2
new     = max(speed - drop, 0)
velocity *= new / speed
```

Note this is **proportional to speed, not speed squared** — it is a decay *rate*,
not a physical friction force. The `stopspeed` floor means slow players decelerate
at a constant rate rather than asymptotically. Getting this wrong is the single
most common way a bhop port feels sluggish.

#### AirMove / air acceleration

```
forward  = flat(view_forward)
right    = flat(view_right)
wishvel  = forward * forward_move + right * side_move   # z zeroed
wishdir  = normalize(wishvel)
wishspeed= length(wishvel)
wishspeed = min(wishspeed, max_speed)                   # 8.128 m/s
if wishspeed > 0: AirAccelerate(wishdir, wishspeed)
```

AirAccelerate:

```
c      = dot(velocity, wishdir)               # wishdir.z == 0, so z is untouched
target = min(wishspeed, 30 u/s)               # 0.762 m/s  <- the key line
addspeed = target - c
if addspeed <= 0: return
budget = airaccel * wishspeed * dt            # uses the UNcapped wishspeed
accelspeed = min(budget, addspeed)            # budget competes with addspeed, NOT with 30
velocity += accelspeed * wishdir
```

This is the single most important function in the project, so its exact behaviour
is worth stating as a closed form. The resulting change in squared speed per tick
is exactly:

| Condition | Gain | Δ\|v\|² per tick |
|---|---|---|
| `c ≥ 30 u/s` | none | `0` |
| `c < 30`, budget ≥ `30 − c` | `30 − c` | `900 − c²` |
| `c < 30`, budget < `30 − c` | budget | `budget² + 2·budget·c` |

(All in u/s; the middle row is the bhop regime and reduces to `0.762² − c²` in
metres.) The peak gain is at `c = 0` — the wish direction exactly 90° from
velocity — and falls off **quadratically** in `c`, which is the cliff edge the
injx document describes. The third row exists and is easy to miss: the budget
competes with `addspeed`, not with the 30 u/s cap, so it only matters once the
wish direction points away from velocity by more than ~96°.

Four things an agent will get wrong:

1. The **30 u/s cap applies to the target, not to the acceleration.** The
   acceleration budget is `airaccel × wishspeed × dt` with the *unclamped*
   wishspeed.
2. **The budget is capped by `addspeed`, not by 30.** Getting this wrong
   produces a visible divergence when strafing into reverse. See §5.6.
3. Because `addspeed = 30 − c`, **you only gain speed while strafing nearly
   perpendicular to your velocity.** At 350 u/s, `c < 30` requires the angle
   between them to be within about 5° of 90°. Turn too little and you gain
   nothing; this is the whole skill of the game.
4. Air acceleration is **additive only**. It never reduces speed except through
   the `c < 0` geometry above. This is what makes the perfect bhop lossless.

Useful reference figures for the gain in the ideal (90°) case, per tick:

| Speed | 64 tick | 128 tick |
|---|---|---|
| 100 u/s | +4.403 u/s | +4.403 u/s |
| 250 u/s | +1.794 u/s | +1.794 u/s |
| 320 u/s | +1.403 u/s | +1.403 u/s |
| 800 u/s | +0.562 u/s | +0.562 u/s |

**Gain per tick is identical at both tickrates** — the 30 u/s cap is a velocity
limit, not a rate. 128 tick simply gets twice as many ticks, so twice the gain
per second for the same turn rate. This is the property `test_air_gain.gd`
asserts.

#### WalkMove (ground only)

```
forward/right from view, as above
wishvel, wishdir, wishspeed  (wishspeed clamped to max speed)
velocity.z = 0
Accelerate(wishdir, wishspeed, 5.5)
velocity.z = 0
# the punishment:
if length(velocity) > max_speed:
    velocity *= max_speed / length(velocity)
move
```

**That clamp is the cost of touching the ground.** One tick on the floor takes a
player at the cap down to roughly 180 u/s. Combined with the velocity modifier
(§6.5) and stamina (§6.4), a missed bhop is punished three separate ways. That is
intentional and is the entire incentive for the auto-hop mode.

The CS-specific `Accelerate` override adds duck/walk modifiers; for a standing
player it reduces to the base form, with one addition:

```
accelspeed = accel * dt * max(250, wishspeed) * surface_friction
```

`max(250, ...)` matters only above 250 u/s wish speed, which cannot happen for a
standing player clamped to `max_speed` = 320. Implement it anyway for parity; it
costs one line.

### 6.4 Stamina (CS:GO's landing penalty)

```
OnLand(fall_velocity):
    stamina = clamp(stamina + 0.050 * fall_velocity, 0, 80)

OnJump(impulse):
    stamina = clamp(stamina + 0.080 * impulse, 0, 80)

every tick:  stamina = max(0, stamina - 60 * dt)
```

Effects, applied where noted:

- in `CheckParameters`: `max_speed *= (1 - stamina/100)²`
- in the jump handler: `jump_impulse *= (1 - stamina/100)`

The **square** on the speed penalty is deliberate — it is there to correlate with
the linear jump penalty. Do not "simplify" it to linear.

At a hard landing (fall velocity ≈ 300 u/s) stamina gains ≈ 15, giving jump
scale ≈ 0.85 and speed scale ≈ 0.72. These match the ~88% / ~75% figures the CS2
document reports for a flat bhop landing, which is a useful cross-check that the
penalty is wired up correctly.

### 6.5 Velocity modifier

`m_flVelocityModifier` starts at 1.0, is multiplied into max speed while
grounded, and recovers at **1/2.5 per second — only on the ground**. In practice
something reduces it on landing or on hard movement; since the reduction site is
outside the movement code, treat it as a tunable whose purpose is:

> Every tick spent on the ground is permanent, compounding speed loss.

Implement the recovery half for certain. If a landing-induced reduction is wanted,
apply it in `OnLand` and calibrate so the net effect matches CS:GO. **Flag this as
an open item in code** — it is the one place where the movement code is not
self-contained.

### 6.6 The jump handler

In order. Each early return is a distinct rule an agent may collapse by mistake.

```
1.  if dead:                                  mark old-buttons jump; return
2.  if water-jumping:                          decay timer; return
3.  if water level >= waist:                  set vertical velocity to swim up; return
4.  if NOT grounded:                          mark old-buttons jump; return
5.  if old-buttons had jump AND NOT autobunnyhopping:   return      # no pogo
6.  if NOT enablebunnyhopping:                 clamp speed to 1.1 x max_speed
7.  clear ground entity                       # <-- THE BUNNYHOP
8.  if crouched:  velocity.z = jump_impulse
    else:         velocity.z += jump_impulse
9.  velocity.z *= (1 - stamina/100)           if stamina > 0
10. FinishGravity                             # half tick of gravity
11. mark old-buttons jump
```

Four rules deserve emphasis because they are the ones that make the timing model
work:

- **Step 4.** A jump pressed while airborne is *not remembered*, and it still
  sets the old-buttons jump bit. So an early press doesn't just fail — it also
  blocks the very next tick. This is the single most important rule for
  reproducing the one-tick performance window.
- **Step 5.** "Don't pogo stick": a jump held from the previous tick is rejected.
  This is what forces a **press-release-press** rhythm rather than a held key, and
  is why the auto-hop controller must emit a one-tick press rather than hold.
- **Step 7.** See §6.1.
- **Step 6.** With bunnyhopping disabled, speed is clamped to 1.1 × max speed
  *at the moment of jumping*. This is a one-time-per-jump clamp, not a continuous
  one.

### 6.7 Ground speed cap: a deliberate divergence from the source

**The source and the required behaviour disagree here, and the required
behaviour won.** This section records the conflict so nobody "fixes" it back.

CS:GO's ground movement ends with a hard clamp on **total** speed
(`CGameMovement::WalkMove`, commented "Additional max speed clamp to keep us from
going faster than allowed while turning"), scaling the velocity vector down to
`m_flMaxSpeed`, which `CCSPlayer::GetPlayerMaxSpeed()` resolves to the weapon
speed. Consequence: in CS:GO, **ground strafing cannot exceed max_speed at all**,
and that clamp is also what makes a missed hop so punishing.

The required behaviour is the opposite: the cap is **per-direction only**, so
strafe-jumping on the floor legitimately exceeds the movement cap. That is the
Quake / CS2 model, and it is the model both learning documents describe ("the
engine doesn't allow you to accelerate past 320 ups *in any one direction*").

### 6.7.1 What the per-direction cap actually produces

With the total clamp removed, the ground speed limit is **emergent**, not a
constant. Per tick, friction removes `v · sv_friction · dt` and ground
acceleration adds at most `sv_accelerate · max(250, wishspeed) · dt`. They
balance at:

```
v_ground_max  =  sv_accelerate * wishspeed / sv_friction
```

Measured, holding W+A and turning:

| turn rate | settled speed | vs max_speed |
|---|---|---|
| 0.3 °/tick (38 °/s) | 322.4 u/s | 1.008× |
| **0.6 °/tick (77 °/s)** | **328.2 u/s** | **1.026×** ← optimum |
| 1.0 °/tick (128 °/s) | 312.0 u/s | 0.975× |
| 2.0 °/tick (256 °/s) | 259.0 u/s | 0.809× |
| 8.0 °/tick (1024 °/s) | 96.5 u/s | 0.302× |

So ground strafing **does** exceed the cap, peaks at 328.2 u/s (1.026×) with a
turn rate around 77 °/s, and is self-limiting from both directions — starting
from 640 u/s it settles back to the same 328.2. Turning too fast is worse than
turning too slowly, because the wish direction swings past perpendicular and
`dot(v, wishdir)` grows.

### 6.7.2 On the 260 / 285 figures

The brief quoted a movement cap of 260 and a strafe top speed of ~285 — a ratio
of 1.096. Those are CS2's numbers (the CS2 document states the bhop cap is
1.1 × 260 = 286). The implementation reproduces the *behaviour*; the exact ratio
depends on the tuning constants, and the source's `sv_accelerate / sv_friction`
ratio of 5.5 / 5.2 yields 1.058 asymptotically, not 1.096:

| `base_max_speed` | ground strafe peak | ratio |
|---|---|---|
| 320 u/s (CS:GO source) | 328.2 u/s | 1.026× |
| 260 u/s (CS2) | 266.6 u/s | 1.026× |

The ratio is invariant to `max_speed`; the absolute number scales with it. To
land on 285 u/s, set `max_speed_units` accordingly — it is exposed on the
player as `@export var max_speed_units`, toggleable at runtime with `G`, and it
is the single number most worth pinning to a measured target.

### 6.7.3 The trade-off you are accepting

Removing the total clamp softens the punishment for a missed hop. Landing above
the ground equilibrium no longer snaps you down to `max_speed` in one tick; you
bleed toward the equilibrium at roughly 4% per tick instead. That is a
real gameplay difference from CS:GO, not a free win. If missed-hop punishment
matters more than ground overspeed, set `csgo_ground_clamp = true` (runtime key
`C`) and the source behaviour returns exactly.

### 6.8 Ground detection

`CategorizePosition` is the heart of the timing model and must be implemented
faithfully, not approximated with Godot's built-in floor state.

The rule that matters: **grounded status is evaluated at the end of a tick and
consumed at the start of the next.** A player who lands halfway through tick N is
*not* seen as grounded until tick N+1. That one-tick delay **is** the CS:GO
performance window. Get it wrong and the timing model silently becomes CS2's.

The ground entity is cleared during a jump, and is set by a downward trace during
movement. A landing fires `OnLand` exactly once, on the transition.

---

## 7. Architecture

### 7.1 Files

As built. Six source files plus three tests.

```
project.godot              128 tick, jitter fix 0, main.tscn as root
main.tscn                  root scene: environment, sky, sun, floor, markers,
                           player + camera, HUD
src/
  cs_movement.gd           pure simulation, RefCounted, no Node/Input deps
  bhop_player.gd           Node3D driver + box-hull sweep via get_rest_info
  test_floor.gd            generated checker texture (speed reference)
  hud.gd                   on-screen speed / mode / jump telemetry
test/
  test_air_gain.gd         air-gain law + tickrate independence
  test_bhop.gd             sim behaviour, flat-ground stub world
  test_live.gd             the same through real Godot physics, plus scene wiring
```

Run them with:

```
godot --headless --path . --script res://test/test_air_gain.gd
godot --headless --path . --script res://test/test_bhop.gd
godot --headless --path . --script res://test/test_live.gd
```

`test_live.gd` exists because the stub world and the real physics server could
easily disagree, and they do not: identical results from both is the only
evidence that the collision abstraction is sound. It also asserts the scene
graph, because the scene is the thing a human actually looks at.

### Script-to-script references use `preload`, not `class_name`

**Do not reference another script by its global `class_name` from a file that
must parse on a cold start.** The registry lives in
`.godot/global_script_class_cache.cfg`, which is a build artifact and is
gitignored. A fresh checkout with no import pass fails to parse *every* script
that names another class, and the cascade looks like unrelated type errors.

Both `cs_movement.gd` and `bhop_player.gd` keep their `class_name` declarations
(they are useful in the editor), but every cross-file reference goes through an
explicit `const MOVEMENT := preload("res://src/cs_movement.gd")`. Verified: with
`.godot/` deleted, a bare `godot --headless --path .` launches with zero errors
and all three suites pass.

### 7.2 `src/cs_movement.gd` — the simulation

A `RefCounted` with **no dependency on `Node`, `Input`, or the scene tree**. This
is not stylistic: it is what makes the simulation testable headlessly and
runnable as a server tick if the project ever grows one.

State:

```
origin            Vector3   # feet position
velocity          Vector3
buttons           int       # this tick
old_buttons       int       # previous tick
grounded          bool
stamina           float
velocity_modifier float
fall_velocity     float
view_angles       Vector2   # yaw/pitch, yaw only affects movement
```

Public surface:

```
tick(dt, buttons, view_angles)   # run one full tick, §6.2
```

Config is either constants or `@export`-style setters — see §7.4.

### 7.3 `src/bhop_player.gd` — the driver

A `Node3D` with a `CollisionShape3D` child holding the hull box.

**Do not use `CharacterBody3D.move_and_slide`.** It is unsuitable here and the
reasoning is worth stating so nobody "simplifies" back to it:

- it owns floor state, and the whole timing model depends on *when* in a tick
  the feet touched the floor;
- it rewrites velocity as part of sliding, which destroys the invariant that a
  perfect bhop leaves horizontal velocity untouched;
- its `apply_floor_snap()` does not project velocity onto the floor plane
  (godotengine/godot#87946), so velocity and actual motion drift apart.

Instead:

- movement via `move_and_collide` / space-state traces;
- `StepMove` reimplemented (§7.5);
- input sampled **once per physics tick**. That single sample *is* the CS:GO
  input packet. Do not poll in `_process`, and do not accumulate events — CS:GO
  is a one-sample-per-tick model, and buffering input across ticks would silently
  reproduce CS2's behaviour instead.

### 7.4 Configuration policy

Constants that genuinely tune feel, and should be settable:

```
tick_rate, enable_bunnyhopping, autobunnyhopping, max_speed, gravity,
jump_impulse, air_accel, air_accel_target, stamina_enabled
```

Everything else is a constant. No config for a value that never changes.

### 7.5 StepMove

The Source version is **three passes, not a fixed iteration loop**:

1. move straight to the destination;
2. retry from a position one step-height higher;
3. retry from a position one step-height lower.

Then, keep whichever of the three got **furthest horizontally**, with a
**ground-normal z threshold of 0.7** on the final trace (anything steeper is
treated as a wall, not a floor). If the up-and-over attempt produced zero net
upward displacement, discard it and fall back to pass 1's result outright.

Implement the threshold and the furthest-wins rule. Both are load-bearing for
corner and stair behaviour.

---

## 8. Modes

The user asked for exactly two. Map them onto the source's own cvars, because
the behaviour then falls out of §6.6 for free instead of being special-cased.

| Mode | Behaviour |
|---|---|
| `MANUAL` | Sampled buttons pass through untouched. No assistance whatsoever. |
| `AUTO` | `autobunnyhopping = 1`. Holding jump keeps re-jumping. |

In `AUTO`, step 5 of §6.6 is bypassed, so a held jump key is enough. The
controller does **not** synthesise the press, does not touch strafe keys, and
does not rotate the view. It only flips one flag.

Note what this means: the `AUTO` mode is a one-line change, because the real
mechanism (clear the ground entity before the ground branch) is in the
simulation, not in a wrapper. If someone ever implements auto-hop *outside* the
jump handler, that is the bug.

---

## 9. Tests

`test/test_bhop.gd`, run with `godot --headless --script`.

No framework, no fixtures. Four checks. They are ordered by importance; the first
is the acceptance criterion and the others exist to localise a failure.

### Test 1 — speed invariance (the acceptance criterion)

Drop the player onto flat ground, hold forward, turn at the optimal angle, run
`AUTO` for 200 hops. Assert horizontal speed is **flat** — no downward trend
across the sequence, within float tolerance.

This is the real proof. A correct controller has a constant ceiling; a broken one
drifts. Assert on the trend across the sequence, not just the final value, so a
controller that bleeds 0.1% per hop still fails.

### Test 2 — the one-tick window

Assert that when the player makes contact with the floor during tick N, **no
jump is processed on tick N**, and the jump processes on tick N+1. This is the
timing rule from §6.8 and the one most likely to be broken by a well-meaning
change to ground detection.

### Test 3 — the ground penalty

Walk one tick at the cap speed and assert the resulting speed lands near
180 u/s (≈ 4.6 m/s). This pins `Friction` and the `WalkMove` clamp together, and
is the check that catches unit-conversion errors immediately — a bot that forgot
to convert will miss by a factor of ~39.

### Test 4 — air gain parity (the "does speed gain match CS:GO" check)

`test/test_air_gain.gd`, standalone, no scene tree required. This is the test that
answers "does gaining speed behave identically to CS:GO", and it is deliberately
written to be checkable by hand.

It sweeps speed × wish-angle × tickrate, runs the literal port of the C++
air-acceleration formula, and asserts the closed form from §6.3:

| Condition | Expected Δ\|v\|² |
|---|---|
| `c ≥ W` | `0` |
| `c < W`, budget ≥ `W − c` | `W² − c²` |
| `c < W`, budget < `W − c` | `budget² + 2·budget·c` |

Plus two direct assertions:

- **Gain per tick is tickrate-independent.** The same speed and wish angle must
  produce the same Δ|v|² at 64 and 128 tick. If this fails, someone has folded
  the tick length into the 30 u/s cap, which is the classic error — the cap is a
  velocity limit, not a rate.
- **Reference values.** At 90° the per-tick gain must match the table in §6.3
  (e.g. +1.4032 u/s at 320 u/s speed) to 1e-4. These came out of the verified
  sweep, so this pins the port against an external number rather than against
  itself.

Because the assertion is a closed form rather than a golden snapshot, it stays
valid if the constants are retuned, and it fails loudly if the formula is
mis-transcribed.

### Optional Test 5 — oracle cross-check

Port the numerical window-averaging procedure from Appendix A of
`bunnyhopping-in-cs2.pdf` to validate `MANUAL` mode outcome classification
against the document's published tables. Only worth doing if `MANUAL` mode is
being tuned; it does not constrain `AUTO`.

### Test 6 — live scene

`test/test_live.gd` instantiates `main.tscn` and drives the real `BhopPlayer`
against the real physics server: settle on the floor, jump and land, then a
900-tick autohop run. The stub and the real server must agree, otherwise the
collision abstraction is unsound.

---

## 9.1 Results as built

All three suites pass under Godot 4.7.2 headless:

```
air gain parity: 40804 checks, 0 failures
bhop sim: 49 checks, 0 failures
  ground strafe peak 328.2 u/s (1.026x max_speed)
  ground bound 338.5 u/s, settles at 328.2 u/s
  12.00 -> 18.44 m/s over 10 jumps, worst per-tick drop 0.000000
  capped at 9.205 m/s (362 u/s)
live scene: 35 checks, 0 failures
  live autohop: 12.00 -> 17.42 m/s over 10 jumps, worst drop 0.0000
  live ground strafe: 328.2 u/s (1.026x max_speed), jumps 0
```

All three pass with `.godot/` deleted, i.e. from a bare checkout.

The load-bearing number is **worst per-tick drop 0.000000**. Across 900 ticks
and 10 jumps the horizontal speed never decreased by even a float epsilon. That
is the perfect bhop working exactly as specified, and it holds identically
through the stub world and through Godot's physics server.

Two numbers worth recording because they refine the plan rather than contradict
it:

- **Jump apex measures 1.418 m, not the continuous ideal 1.4478 m.** Discrete
  integration at 128 tick undershoots, and the jump tick applies half a tick of
  gravity twice, exactly as the source does. The test allows 3.5%; a 10% error
  in jump impulse or gravity still fails.
- **With bunnyhopping disabled, speed settles at 362 u/s, not 352.** The 1.1×
  clamp is a jump-time event, not a continuous cap, so the airborne ticks add
  roughly 3% back on top before the next jump re-clamps. This is correct
  behaviour, and the original "speed sits exactly on the cap" expectation was
  wrong.

---

## 10. Task breakdown

Suggested order. Each is independently verifiable.

| # | Task | Depends on | Verified by |
|---|---|---|---|
| 1 | Project skeleton, constants file, `project.godot` at 128 tick | — | headless script runs |
| 2 | `test_air_gain.gd` — **verify the air-gain law before writing any sim code** | 1 | `godot --headless --script test/test_air_gain.gd` |
| 3 | `cs_movement.gd` skeleton: state, `tick()`, §6.2 ordering | 1 | structure only |
| 4 | `Friction` | 3 | Test 3 (partial) |
| 5 | `Accelerate` + `WalkMove` incl. the max-speed clamp | 3 | Test 3 |
| 6 | `AirMove` + `AirAccelerate` — must match the law proven in task 2 | 3, 2 | Test 4 |
| 7 | Collision: hull, `TryPlayerMove`, `ClipVelocity`, `StepMove` | 1 | manual walk test |
| 8 | `CategorizePosition` + `OnLand` — the one-tick window | 7 | Test 2 |
| 9 | `CheckJumpButton` — the whole of §6.6 | 8 | Test 1 |
| 10 | Stamina + velocity modifier (§6.4, §6.5) | 9 | Test 1 |
| 11 | `bhop_player.gd` driver + input sampling | 7 | manual play |
| 12 | `MANUAL` / `AUTO` modes | 9, 11 | Test 1 in AUTO |
| 13 | `test_bhop.gd` | all | `godot --headless` |

Tasks 2, 8 and 9 are the critical path. Task 2 is listed early on purpose: the
air-gain law is the one piece of the physics that is cheap to prove standalone
and expensive to debug inside a running simulation. It is already written and
passes — an agent should run it before touching `cs_movement.gd` so that any
later speed discrepancy is unambiguously a wiring bug rather than a formula bug.

Tasks 7 and 8 are the critical path. Tasks 3–5 are mechanical once the ordering
is right, and are best done in parallel by different agents.

---

## 11. Failure modes to watch for

Ranked by how often they actually happen. The top four were all hit during the
initial build, so treat them as known-live rather than theoretical.

1. **Using `move_and_slide`.** Destroys the timing model and the velocity
   invariant. See §7.3.
2. **Buffering input across ticks.** Makes CS:GO behave like CS2 and silently
   destroys the one-tick window. Sample exactly once per tick.
3. **Deciding grounded state immediately on contact.** Removes the one-tick
   delay. This is the defining rule of the model.
4. **Both halves of the gravity split must subtract.** Writing the first half as
   `+=` makes the two halves cancel exactly, so `velocity.y` never accumulates
   downward and the player flies away at constant velocity. This is invisible in
   any test that does not watch a full jump arc, and it is the single worst bug
   in the build. See §6.2.
5. **Treating the 30 u/s wish-speed cap as a rate instead of a velocity limit.**
   It caps the *target*; `g` is a per-tick velocity delta, so gain per tick is
   identical at 64 and 128 tick. Multiplying by `dt` anywhere in
   `AirAccelerate` is the most likely error in that function. See §6.3.
6. **Capping the acceleration budget by 30 instead of by `addspeed`.** They
   coincide in the bhop regime and diverge when strafing into reverse. Invisible
   in normal play, wrong nonetheless. See §5.6, §6.3.
7. **Converting friction into a force** (speed² instead of speed). See §6.3.
8. **Not establishing ground at spawn.** A player resting on a surface has
   `velocity.y == 0` on every grounded tick, so it never sweeps into the floor
   and the ground state never turns on. Source gets this free because its ground
   entity persists. `reset()` therefore probes downward once. See §6.8.
9. **Omitting the velocity modifier recovery** or making it recover while
   airborne. It must be ground-only.
10. **Undoing the stamina square.** See §6.4. Also note the stamina *cost*
    constants must be divided by `U` — they are per Source unit of velocity but
    compared against a unitless range, so porting them literally makes stamina a
    no-op.
11. **Using a capsule hull instead of the box.** Different corner behaviour.
12. **Auto-hop implemented in the driver instead of in the jump handler.** See §8.
13. **Using 102.4 as a tickrate.** It is an updaterate, and 1/102.4 is not
    exactly representable in binary floating point. See §5.6.
14. **Reading a collision normal out of `intersect_shape()`.** In Godot 4 it
    returns only `rid`, `collider_id`, `collider`, `shape` — no `normal`. Use
    `get_rest_info()`, which does return one but requires genuine overlap.
15. **Referencing another script by `class_name` from a cold start.** The global
    class registry is a gitignored build artifact, so a fresh checkout fails to
    parse everything that names another class, and the resulting cascade of
    "Identifier not declared" and "cannot infer type" errors looks like unrelated
    type problems. Use `preload`. See §7.1.
16. **A floor you cannot measure speed against.** A flat single-colour plane
    makes 8 m/s and 18 m/s look identical. This is a testing defect, not a
    cosmetic one: the checker texture and the distance markers exist so the
    whole point of the project is observable.

---

## 12. Open questions

**1. What is the real cap speed?**
This repository ships `sv_maxspeed = 320`, giving a 1.1× cap of 352 u/s
(8.9408 m/s). Live CS:GO players are widely reported to top out near 320 u/s.
The shipped defaults almost certainly differ from what the game mode cvars deploy.
→ **Default to the source values and expose `max_speed` as a constant.** If a
target top speed is known, pin it there. This is the single number most worth
getting right, and Test 1 will not catch a wrong one.

**2. What reduces `m_flVelocityModifier` on landing?**
Its recovery is in the CS movement code but the reduction site is not — it is
outside the movement layer. §6.5 specifies the intent and the recovery. The
reduction needs calibrating against observed CS:GO behaviour.

**3. ~~64 or 128 tick?~~ RESOLVED — 128.** See §5.6. Note the cost: the bhop
window halves to 7.8125 ms, which makes `MANUAL` mode harder. `AUTO` mode is
unaffected, being tick-exact by construction.

---

## 13. Reference documents

- `bunnyhopping-in-cs2.pdf` — §3 jump outcome taxonomy, §3 tick timing,
  §3 cooldown, Appendix A closed-form performance numbers.
- `Strafing Theory by injx.pdf` — the *why* of §6.3. Re-derived in CS terms in
  this plan; the Quake parameterisation differs and must not be copied directly.
- CS:GO movement source — see §3.2. Specifications restated above; consult only
  to resolve genuine ambiguity.

---

## 14. Open decision: the ground clamp

Resolved in favour of the requested behaviour (ground strafing may exceed
`max_speed`), because that is the model both learning documents describe. The
source-faithful alternative is one flag away: `csgo_ground_clamp`, runtime key
`C`. See §6.7.

Still open: the absolute value of `max_speed_units`. The source says 320, CS2
says 260, and the brief quoted 260 with a 285 strafe top speed. Whichever is
chosen, set it on the player's exported `max_speed_units` rather than editing
constants, so the HUD and tests can be checked against the same number.
