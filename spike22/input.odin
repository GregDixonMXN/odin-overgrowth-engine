package spike22

import "core:math"
import rl "vendor:raylib"
// spike22 gamepad: OG layout on pad 0 — left stick move, right stick
// look, RB jump, LB guard, RT slash, LT kick, L3 sneak, X pickup,
// Y ragdoll, B recover, Start rematch (+ rumble on connects).
// pad_read runs once per frame; every helper is false/zero with no pad,
// so headless runs stay diff-clean.
PAD_DZ :: 0.075
g_pad_dz := f32(PAD_DZ) // settings-adjustable (saved)

PadState :: struct {
    active:      bool,
    move:        [2]f32, // x right+, y forward+
    look:        [2]f32, // x right+, y up+
    flick:       int,    // stick-flick tap this frame (1W 2S 3D 4A, else 0)
    rt, lt:      bool,   // trigger edges this frame
    rt_down:    bool,
    lt_down:    bool,
    prev_sector: int,
    prev_rt:    f32,
    prev_lt:    f32,
}
g_pad: PadState

pad_dz :: proc(v: f32) -> f32 {
    dz := g_pad_dz
    if v > -dz && v < dz { return 0 }
    return (v - (dz if v > 0 else -dz)) / (1 - dz)
}

pad_read :: proc() {
    g_pad.flick = 0
    g_pad.rt = false
    g_pad.lt = false
    if !rl.IsGamepadAvailable(0) {
        g_pad.active = false
        g_pad.move = {}
        g_pad.look = {}
        g_pad.prev_sector = 0
        return
    }
    g_pad.active = true
    mx := pad_dz(rl.GetGamepadAxisMovement(0, .LEFT_X))
    my := pad_dz(-rl.GetGamepadAxisMovement(0, .LEFT_Y))
    g_pad.move = {mx, my}
    g_pad.look = {pad_dz(rl.GetGamepadAxisMovement(0, .RIGHT_X)), pad_dz(-rl.GetGamepadAxisMovement(0, .RIGHT_Y))}
    // stick flick: entering a direction sector from elsewhere = tap
    // (drives the double-tap dodge window)
    sector := 0
    if mx * mx + my * my > 0.1225 {
        if math.abs(mx) > math.abs(my) { sector = 3 if mx > 0 else 4 } else { sector = 1 if my > 0 else 2 }
    }
    if sector != 0 && sector != g_pad.prev_sector { g_pad.flick = sector }
    g_pad.prev_sector = sector
    // analog triggers: edge past 0.4 (either rest polarity)
    rt := rl.GetGamepadAxisMovement(0, .RIGHT_TRIGGER)
    lt := rl.GetGamepadAxisMovement(0, .LEFT_TRIGGER)
    if rt > 0.4 && g_pad.prev_rt <= 0.4 { g_pad.rt = true }
    if lt > 0.4 && g_pad.prev_lt <= 0.4 { g_pad.lt = true }
    g_pad.prev_rt = rt
    g_pad.prev_lt = lt
    g_pad.rt_down = rt > 0.2
    g_pad.lt_down = lt > 0.2
}

pad_jump_pressed  :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN) } // A
pad_jump_down     :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonDown(0, .RIGHT_FACE_DOWN) } // A
pad_dodge         :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_TRIGGER_1) } // RB
pad_guard_down    :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonDown(0, .LEFT_TRIGGER_1) }
pad_sneak_down    :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonDown(0, .LEFT_THUMB) }
pad_pickup        :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_LEFT) }
pad_throw         :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_UP) } // dpad up
pad_grab          :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_DOWN) } // dpad down
pad_ragdoll       :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_UP) }
pad_recover       :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_RIGHT) }
pad_rematch       :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .MIDDLE_RIGHT) }
// menu nav (dpad edges + A confirm + B back; all-false headless)
pad_menu_up       :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_UP) }
pad_menu_down     :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_DOWN) }
pad_menu_left     :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_LEFT) }
pad_menu_right    :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .LEFT_FACE_RIGHT) }
pad_menu_confirm  :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN) }
pad_menu_back     :: proc() -> bool { return g_pad.active && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_RIGHT) }

// NOTE: pad_rumble is wired but raylib/GLFW has no force feedback on PC
// (SetGamepadVibration warns "not available"), so connects stay quiet
// for now. Kept for future platforms.
pad_rumble :: proc(left, right, dur: f32) {
    if g_pad.active { rl.SetGamepadVibration(0, left, right, dur) }
}
