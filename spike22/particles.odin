package spike22

import "core:math"
import rl "vendor:raylib"
// spike22 particles: single CPU pool, box puffs, no allocation after init.
// dust on landings/vaults, spark+blood on connects, big burst on KO.
// Visual-only: no gameplay state, no log lines.
PART_MAX :: 256

Particle :: struct {
    alive: bool,
    pos:   [3]f32,
    vel:   [3]f32,
    life:  f32,
    span:  f32,
    size:  f32,
    color: rl.Color,
}

Parts :: struct {
    pool: [PART_MAX]Particle,
    next: int,
}

parts_spawn :: proc(ps: ^Parts, p: [3]f32, v: [3]f32, span, size: f32, c: rl.Color) {
    s := &ps.pool[ps.next]
    ps.next = (ps.next + 1) % PART_MAX
    s.alive = true
    s.pos = p
    s.vel = v
    s.life = span
    s.span = span
    s.size = size
    s.color = c
}

// deterministic puff ring: index-driven directions, no rng (auto stays diff-clean)
parts_burst :: proc(ps: ^Parts, at: [3]f32, n: int, span, size: f32, c: rl.Color, up: f32) {
    for i in 0 ..< n {
        a := f32(i) * 2.39996 // golden angle spreads evenly
        r := 1.0 + 0.35 * f32(i % 3)
        v := [3]f32{math.cos(a) * r, up * (0.6 + 0.4 * f32(i % 2)), math.sin(a) * r}
        parts_spawn(ps, at, v, span * (0.8 + 0.2 * f32(i % 2)), size, c)
    }
}

parts_update :: proc(ps: ^Parts, dt: f32) {
    for i in 0 ..< PART_MAX {
        s := &ps.pool[i]
        if !s.alive { continue }
        s.life -= dt
        if s.life <= 0 { s.alive = false; continue }
        s.vel.y -= 6.0 * dt // light gravity (dust hangs, sparks fall)
        s.pos += s.vel * dt
    }
}

parts_render :: proc(ps: ^Parts) {
    for i in 0 ..< PART_MAX {
        s := &ps.pool[i]
        if !s.alive { continue }
        t := s.life / s.span
        e := s.size * (0.3 + 0.7 * t)
        rl.DrawCube({s.pos.x, s.pos.y, s.pos.z}, e, e, e, s.color)
    }
}

DUST :: rl.Color{185, 155, 120, 255}
SPARK :: rl.Color{255, 220, 130, 255}
BLOOD :: rl.Color{170, 30, 30, 255}

g_parts: Parts // one pool for the whole match

// ---- blood decals ----
// Persistent dark stamps where hits land. Ring of 64 flat quads on the
// dirt (zero-size until first use, so nothing draws at the origin).
// Visual-only: no gameplay, no log lines.
DEC_MAX :: 64
Decal :: struct {
    pos:  [3]f32,
    size: f32,
}
g_decals: [DEC_MAX]Decal
g_decal_next: int

decal_stamp :: proc(x, z, gy: f32, size: f32) {
    d := &g_decals[g_decal_next]
    g_decal_next = (g_decal_next + 1) % DEC_MAX
    d.pos = {x, gy + 0.03, z}
    d.size = size
}

decals_render :: proc() {
    for i in 0 ..< DEC_MAX {
        d := &g_decals[i]
        if d.size <= 0 { continue }
        rl.DrawPlane({d.pos.x, d.pos.y, d.pos.z}, {d.size, d.size}, rl.Color{120, 10, 10, 255})
    }
}
