package spike22

import "core:c"
import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import rl "vendor:raylib"
import jph "../thirdparty/joltc-odin"
// spike22 combat: triggers, attack input, strikes, cancel windows.
// Spike 21: CANCEL WINDOWS. Overgrowth-style (cf. UpdateAttacking +
// "cancel" status key): once the strike lands, J/K chains a fresh attack
// mid-recover (combos) and SPACE jump-cancels out. Whiffs (no contact)
// can't cancel — commitment is punishable. AI chains on hit too.

g_kos_you, g_kos_dummy: int

// ---- barks: event one-liners over the HUD (3s each, 4-deep horn queue) ----
Bark :: struct { who: cstring, text: cstring, t: f32 }
g_barks: [4]Bark
g_firstblood, g_matchpoint, g_decided: bool
bark_say :: proc(ctx: ^Ctx, who, text: cstring, dur := f32(3.0)) {
    for &b in g_barks {
        if b.t <= 0 {
            b.who = who; b.text = text; b.t = dur
            if ctx.auto { fmt.printf("f=%d BARK %s: %s\n", ctx.frame, who, text) }
            return
        }
    }
    g_barks[0] = g_barks[1]; g_barks[1] = g_barks[2]
    g_barks[2] = g_barks[3]; g_barks[3] = {who, text, dur}
    if ctx.auto { fmt.printf("f=%d BARK %s: %s\n", ctx.frame, who, text) }
}
barks_tick :: proc(dt: f32) {
    for &b in g_barks { if b.t > 0 { b.t -= dt } }
}

WIN_SCORE :: 5 // first to 5 KOs takes the match

// match over when either side hits the score (kos_dummy = your deaths)
match_over :: proc() -> bool {
    return g_kos_you >= WIN_SCORE || g_kos_dummy >= WIN_SCORE
}

// ---- triggers ----
combat_triggers :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx) {
    bi := ctx.bi
    dt := ctx.dt
    // held: dragged with the holder, struggle burns down (mash breaks early)
    if f.grabbed_by != nil {
        h := f.grabbed_by
        if h.grab_victim != f || h.mode != .Anim || h.hp <= 0 || f.hp <= 0 {
            grab_release(f) // holder lost it (ragdolled, died, threw)
        } else if f.mode == .Anim && f.grounded {
            f.hold_t -= dt
            if f.hold_t <= 0 {
                grab_release(f)
                away := f.bumper_pos - h.bumper_pos; away.y = 0
                if al := linalg.length(away); al > 1e-4 { f.bumper_vel = away / al * 3.0 }
                if ctx.auto || f.is_player {
                    fmt.printf("f=%d BREAKS %s\n", ctx.frame, f.name)
                }
            } else {
                // drag: pull toward the hold point by velocity (never snap —
                // teleports bury kinematic bodies and NaN the physics).
                // Stretched past 3m, the hold tears free.
                fx := math.sin(h.yaw); fz := math.cos(h.yaw)
                hx := h.bumper_pos.x + fx * 0.9
                hz := h.bumper_pos.z + fz * 0.9
                dx := hx - f.bumper_pos.x
                dz := hz - f.bumper_pos.z
                dd := math.sqrt(dx * dx + dz * dz)
                if dd > 3.0 {
                    grab_release(f)
                    if ctx.auto || f.is_player {
                        fmt.printf("f=%d TORN %s\n", ctx.frame, f.name)
                    }
                } else {
                    sp := min(dd * 8.0, 3.0)
                    if dd > 1e-4 { f.bumper_vel = [3]f32{dx / dd * sp, 0, dz / dd * sp} }
                    else { f.bumper_vel = {0, 0, 0} }
                    f.yaw = math.atan2(h.bumper_pos.x - f.bumper_pos.x, h.bumper_pos.z - f.bumper_pos.z)
                }
            }
        }
    }
    // hurt stamp + out-of-combat regen (manual/autoai only — the plain
    // auto demo needs its 1-HP dummies fragile). 6s calm, then +1 HP/4s.
    if f.hp < f.prev_hp { f.hurt_f = ctx.frame; f.regen_acc = 0 }
    f.prev_hp = f.hp
    if (ctx.brains || !ctx.auto) && f.hp > 0 && f.hp < f.max_hp && !f.dying && ctx.frame - f.hurt_f > 360 {
        f.regen_acc += dt
        if f.regen_acc >= 4.0 {
            f.regen_acc = 0
            f.hp += 1
            f.prev_hp = f.hp
            if ctx.auto { fmt.printf("f=%d REGEN %s hp=%d\n", ctx.frame, f.name, f.hp) }
        }
    }
    if f.is_player {
        if f.hp <= 0 {
            // K.O.: back at origin in 5s (match over: stay down)
            f.respawn_t += dt
            if f.respawn_t > 5.0 && !match_over() {
                fighter_respawn(f, bi, {0, 0, 0}, ctx.hf)
                fmt.printf("f=%d YOU RESPAWN\n", ctx.frame)
            }
        } else if f.mode == .Ragdoll && (!ctx.auto || ctx.brains) {
            // knocked down: get up on your own in 2.5s (T hurries it).
            // Without this one hit takes you out of the fight for good.
            f.handoff_age += dt
            if f.handoff_age > 2.5 {
                fighter_recover(f, bi, {0, -1, 0}, ctx.hf)
                if f.mode == .Anim { fmt.printf("f=%d YOU UP\n", ctx.frame) }
            }
        }
        if f.mode == .Anim && (rl.IsKeyPressed(.R) || pad_ragdoll() || (ctx.auto && ctx.frame == 120 && f.is_player)) {
            hv := [3]f32{f.bumper_vel.x, f.vy if !f.grounded else 0, f.bumper_vel.z}
            fighter_handoff(f, bi, hv, false)
            fmt.printf("f=%d RAGDOLL\n", ctx.frame)
        } else if f.mode == .Ragdoll && (rl.IsKeyPressed(.T) || pad_recover() || (ctx.auto && ctx.frame == 230 && f.is_player)) {
            fighter_recover(f, bi, {0, -1, 0}, ctx.hf)
            if f.mode == .Anim { fmt.printf("f=%d RECOVER @ %v\n", ctx.frame, f.bumper_pos) }
        }
    } else {
        if f.hp <= 0 {
            // K.O.: next challenger runs in ahead of the player
            // (match over: no new challengers)
            f.respawn_t += dt
            if f.respawn_t > 5.0 && foe != nil && !match_over() {
                fighter_respawn(f, bi, {foe.bumper_pos.x, 0, foe.bumper_pos.z + 4.0}, ctx.hf)
                fmt.printf("f=%d CHALLENGER hp=%d\n", ctx.frame, f.hp)
            }
        } else if f.mode == .Ragdoll && foe != nil {
            // auto demo: never leave a dummy behind — run it back in ahead
            // (manual play keeps AI walk-back instead; allies regroup via escort)
            gap := foe.bumper_pos - f.bumper_pos
            if ctx.auto && f.team == 1 && math.sqrt(gap.x * gap.x + gap.z * gap.z) > 10.0 {
                fighter_recover(f, bi, {foe.bumper_pos.x, 0, foe.bumper_pos.z + 4.0}, ctx.hf)
                fmt.printf("f=%d REDEPLOY ahead hp=%d\n", ctx.frame, f.hp)
            } else {
                // dummy: auto-recover 4s after a handoff
                f.handoff_age += dt
                if f.handoff_age > 4.0 {
                    fighter_recover(f, bi, {0, -1, 0}, ctx.hf)
                    fmt.printf("f=%d DUMMY UP\n", ctx.frame)
                }
            }
        } else if f.mode == .Anim && !f.is_player && ctx.auto && foe != nil {
            // auto demo: stranded standing dummy jogs back via teleport
            // (allies hold their post; escort moves them in manual/autoai)
            gap := foe.bumper_pos - f.bumper_pos
            if f.team == 1 && math.sqrt(gap.x * gap.x + gap.z * gap.z) > 12.0 {
                // perched lookouts hold their roof
                ty, _ := height_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z)
                if f.bumper_pos.y - ty < 2.0 {
                    fighter_recover(f, bi, {foe.bumper_pos.x, 0, foe.bumper_pos.z + 4.0}, ctx.hf)
                    fmt.printf("f=%d REDEPLOY standing hp=%d\n", ctx.frame, f.hp)
                }
            }
        }
    }
    f.do_anim = f.mode == .Anim
}

// ---- perception ----
// Sight (18m + line-of-sight; sneaking hides past 6m) plants exact info;
// loud noises plant last-knowns; info older than 240 frames dies. No
// omniscient hunters: what you can't see or hear, you walk to and check.
Noise :: struct { pos: [3]f32, radius: f32, frame: int }
g_noises: [8]Noise
g_noise_next: int

noise_push :: proc(pos: [3]f32, radius: f32, frame: int) {
    n := &g_noises[g_noise_next]
    g_noise_next = (g_noise_next + 1) % 8
    n.pos = pos
    n.radius = radius
    n.frame = frame
}

// segment vs building masses + terrain: true = clear view
los_clear :: proc(hf: ^Heightfield, a, b: [3]f32) -> bool {
    for i in 1 ..< 8 {
        k := f32(i) / 8.0
        p := a + (b - a) * k
        if arena_point_blocked(p) { return false }
        if h, ok := height_at(hf, p.x, p.z); ok && h > p.y + 0.2 { return false }
    }
    return true
}
// CHASE 0: close distance. CIRCLE 1: orbit on the striking ring (no
// beeline stacking). RETREAT 2: give ground after swinging (cautious
// fighters more often). STRIKE 3: plant feet, swing on cooldown.
// Manual play only — the auto demo holds still (baseline-stable).
ai_roll :: proc(frame: int, x, z, s: f32) -> f32 {
    h := f32(math.abs(math.sin(f32(frame) * 0.37 + x * 1.7 + z * 2.3 + s * 5.1)) * 7.0)
    return h - math.floor(h)
}

ai_drive :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx, accel: ^[3]f32) {
    f.ai_want = 0
    if (ctx.auto && !ctx.brains) || foe == nil { return }
    if f.stagger_t > 0 { return } // flinch: ride the shove, no orders
    if f.grabbed_by != nil { f.ai_want = 0; return } // held: struggle, no orders
    // perceive: sight refreshes exact info, noises plant last-knowns.
    // Everyone steers at the info, never at the true body — except the
    // swing itself, which needs eyes on the foe.
    to_true := foe.bumper_pos - f.bumper_pos
    to_true.y = 0
    tdist := linalg.length(to_true)
    sees := false
    if tdist < 2.5 {
        // close senses: breathing distance sees through walls
        sees = true
        f.info_pos = foe.bumper_pos
        f.info_frame = ctx.frame
    } else if tdist < 18.0 {
        if !(foe.sneaking && tdist > 6.0) {
            a := f.bumper_pos + [3]f32{0, 1.4, 0}
            b := foe.bumper_pos + [3]f32{0, 1.4, 0}
            if los_clear(ctx.hf, a, b) {
                sees = true
                f.info_pos = foe.bumper_pos
                f.info_frame = ctx.frame
            }
        }
    }
    if !sees {
        for n in g_noises {
            dx := n.pos.x - f.bumper_pos.x
            dz := n.pos.z - f.bumper_pos.z
            if n.frame > f.info_frame && dx * dx + dz * dz < n.radius * n.radius {
                f.info_pos = n.pos
                f.info_frame = n.frame
            }
        }
    }
    if !f.has_sword {
        // unarmed: loose steel is the objective — walk the nearest blade
        // down (info override steers the chase; grab lands on proximity)
        for &d in g_drops {
            if !d.active || d.thrown { continue }
            dx := d.pos.x - f.bumper_pos.x
            dz := d.pos.z - f.bumper_pos.z
            if dd := math.sqrt(dx * dx + dz * dz); dd < 3.0 {
                f.info_pos = {d.pos.x, f.bumper_pos.y, d.pos.z}
                f.info_frame = ctx.frame
                if dd < 1.5 { combat_try_pickup(f, ctx) }
                break
            }
        }
    }
    tgt := foe.bumper_pos if sees else f.info_pos
    to_f := tgt - f.bumper_pos
    to_f.y = 0
    dist := linalg.length(to_f)
    if foe.hp <= 0 || foe.mode != .Anim || tdist > 30.0 {
        if tdist > 0.01 { f.yaw = math.atan2(to_true.x, to_true.z) }
        return // dead/down/far foe: hold, face
    }
    dir := to_f / max(dist, 1e-4)
    dt := ctx.dt
    f.ai_cool -= dt
    f.ai_t -= dt
    // escort: our side's AI regroups past 6m unless a foe is right here
    if f.team == 0 && !f.is_player {
        ax := ctx.ally_anchor.x - f.bumper_pos.x
        az := ctx.ally_anchor.z - f.bumper_pos.z
        ad := math.sqrt(ax * ax + az * az)
        if ad > 6.0 && tdist > f.ai_range + 1.0 {
            accel^ = [3]f32{ax / max(ad, 1e-4), 0, az / max(ad, 1e-4)} * f.accel_rate
            if dist > 0.01 { f.yaw = math.atan2(to_f.x, to_f.z) }
            return
        }
    }
    // v2: hurt caution (below 40% = longer cools, likelier retreats)
    hurt := f.max_hp > 1 && f.hp * 5 <= f.max_hp * 2
    // v2b: critical fighters (<=25%) flee close threats; cornered ones
    // cower. Perched criticals hold the top instead (no suicide dives).
    if f.max_hp > 1 && f.hp * 4 <= f.max_hp && tdist < 10.0 && f.ai_state != 4 && f.ai_state != 5 {
        perched := false
        if f.grounded {
            if gyb, okb := ground_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z, f.bumper_pos.y + 0.5); okb {
                if gyt, okt := height_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z); okt && gyb - gyt > 0.6 {
                    perched = true
                }
            }
        }
        if !perched {
            f.ai_state = 4 // FLEE
            f.ai_t = 3.0
            if ctx.auto {
                fmt.printf("f=%d FLEE %s\n", ctx.frame, f.name)
            }
            bark_say(ctx, "horn", "THEY FALL BACK")
            // engage now: the switch below dispatched on the old state
            tangent := [3]f32{-dir.z, 0, dir.x} * f.ai_dir
            accel^ = (-dir + tangent * 0.3) * f.accel_rate
            if dist > 0.01 { f.yaw = math.atan2(to_f.x, to_f.z) }
            return
        }
    }
    // v2: darters sidestep early swings (brutes tank it out)
    if foe.atk_anim != nil && foe.atk_t < 0.18 && tdist < 3.5 && tdist > 0.01 && f.dodge_cd <= 0 && f.grounded && !f.dying && f.ai_aggr <= 0.6 {
        if f.ai_dir == 0 {
            f.ai_dir = 1.0 if ai_roll(ctx.frame, f.bumper_pos.x, f.bumper_pos.z, 5.0) < 0.5 else -1.0
        }
        f.dodge_t = 0.22
        f.dodge_cd = 0.9
        f.dodge_dir = [3]f32{-dir.z, 0, dir.x} * f.ai_dir
        f.stagger_t = 0
        if f.atk_anim != nil && !f.connected { f.atk_t = f.atk_dur }
        sfx_playi(SFXW_WHOOSH)
        feet := [3]f32{f.bumper_pos.x, f.bumper_pos.y + 0.15, f.bumper_pos.z}
        parts_burst(&g_parts, feet, 8, 0.4, 0.12, DUST, 1.0)
        f.ai_state = 1 // slipped the swing: re-enter via the ring
        f.ai_t = 0.8
        return
    }
    if !sees && dist < 1.5 {
        // walked into the last-known and found air: hold, keep watching
        accel^ = {}
        if dist > 0.01 { f.yaw = math.atan2(to_f.x, to_f.z) }
        return
    }
    switch f.ai_state {
    case 0: // CHASE
        accel^ = dir * f.accel_rate
        if f.grounded { // v2 perch discipline: don't walk off tops after far foes
            gy_box, okb := ground_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z, f.bumper_pos.y + 0.5)
            if okb {
                gy_terr, okt := height_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z)
                if okt && gy_box - gy_terr > 0.6 && foe.bumper_pos.y < f.bumper_pos.y - 2.0 && tdist > 9.0 {
                    accel^ = {} // hold the high ground until they close
                    return
                }
            }
        }
        if dist < f.ai_range {
            f.ai_state = 3 // STRIKE
        } else if dist < f.ai_range + 5.0 && f.ai_t <= 0 {
            f.ai_state = 1 // CIRCLE
            f.ai_dir = 1.0 if ai_roll(ctx.frame, f.bumper_pos.x, f.bumper_pos.z, 1.0) < 0.5 else -1.0
            f.ai_t = 1.0 + ai_roll(ctx.frame, f.bumper_pos.x, f.bumper_pos.z, 2.0) * 1.5
        }
    case 1: // CIRCLE: orbit + hold the ring
        tangent := [3]f32{-dir.z, 0, dir.x} * f.ai_dir
        radial := dir * math.clamp((dist - f.ai_range) * 1.5, -1.0, 1.0)
        accel^ = (tangent * 0.8 + radial) * f.accel_rate
        if f.grab_victim != nil {
            // hands full: keep dragging, throw before they break out
            if f.grab_victim.grabbed_by != f || f.grab_victim.hp <= 0 { f.grab_victim = nil }
            else if f.grab_victim.hold_t <= 0.5 { combat_throw_victim(f, ctx) }
        } else if f.carry_idx >= 0 {
            // crate overhead: hurl it once aimed (cool set at lift)
            if f.ai_cool <= 0 && foe.hp > 0 && sees { combat_hurl_crate(f, ctx); f.ai_cool = 1.5 }
        } else if f.grab_victim == nil && f.grabbed_by == nil && f.ai_cool <= 0 && foe.hp > 0 && sees && tdist > 4.0 && tdist < 12.0 {
            // heavy labor: crate nearby and a foe at hurl range — lift it
            for ci in 0 ..< 6 {
                if crate_state[ci] != 0 { continue }
                if dd := linalg.length(crate_pos(ctx, ci) - f.bumper_pos); dd < 2.5 {
                    combat_try_lift(f, ctx)
                    if f.carry_idx >= 0 { f.ai_cool = 1.0 }
                    break
                }
            }
        } else if f.has_sword && !f.kicks && tdist > 3.8 && tdist < 9.0 && f.ai_cool <= 0 && foe.hp > 0 && sees {
            f.ai_want = 3 // huck steel while orbiting — never walk into it
            f.ai_cool = 2.0
        }
        if dist < f.ai_range - 0.2 && f.grab_victim == nil {
            f.ai_state = 3 // drifted into range: strike (holders keep dragging)
        } else if f.ai_t <= 0 {
            f.ai_state = 0 // CHASE
            f.ai_t = 1.0
        }
    case 2: // RETREAT: back off, then re-enter via the ring
        accel^ = -dir * f.accel_rate * 0.8
        if f.ai_t <= 0 {
            f.ai_state = 1 // CIRCLE
            f.ai_t = 1.0 + ai_roll(ctx.frame, f.bumper_pos.x, f.bumper_pos.z, 3.0)
        }
    case 4: // FLEE: full flight, slight weave; cornered -> cower
        tangent := [3]f32{-dir.z, 0, dir.x} * f.ai_dir
        accel^ = (-dir + tangent * 0.3) * f.accel_rate
        if tdist < 2.5 && f.speed < 0.5 {
            f.ai_state = 5 // COWER
            f.ai_t = 2.0
            if ctx.auto {
                fmt.printf("f=%d COWER %s\n", ctx.frame, f.name)
            }
        } else if f.ai_t <= 0 || tdist > 12.0 {
            f.ai_state = 1 // caught breath: re-enter via the ring
            f.ai_t = 1.0
        }
    case 5: // COWER: guard up, no swings, wait it out
        accel^ = {}
        f.block_t = 0.3 // held cower (input latch rebuilds guard)
        if f.ai_t <= 0 || dist > 5.0 {
            f.ai_state = 1 // CIRCLE
            f.ai_t = 1.0
        }
    case: // STRIKE: plant feet, swing on cooldown
        accel^ = {}
        if dist > f.ai_range + 0.5 {
            f.ai_state = 0 // CHASE
            f.ai_t = 0.5
        } else if f.grab_victim != nil {
            if f.grab_victim.grabbed_by != f || f.grab_victim.hp <= 0 { f.grab_victim = nil }
            else if f.grab_victim.hold_t <= 0.5 {
                combat_throw_victim(f, ctx)
                f.ai_state = 1 // CIRCLE
                f.ai_t = 1.0
            }
        } else if f.carry_idx >= 0 {
            if f.ai_cool <= 0 && foe.hp > 0 && sees {
                combat_hurl_crate(f, ctx) // planted throw
                f.ai_cool = 1.5
            }
        } else if f.grabbed_by == nil && f.carry_idx < 0 && dist < 1.8 && f.ai_cool <= 0 && foe.hp > 0 && sees && f.ai_aggr >= 0.5 {
            combat_try_grab(f, foe, ctx) // clinch: latch and drag
            f.ai_cool = 1.5
            f.ai_state = 1 // CIRCLE
            f.ai_t = 1.5
        } else if f.ai_cool <= 0 && foe.hp > 0 && sees && f.grab_victim == nil && f.carry_idx < 0 {
            f.ai_want = 2 if f.kicks else 1 // brute kicks, cutthroat slashes
            f.ai_cool = (1.0 + (1.0 - f.ai_aggr) * 1.5) * (1.6 if hurt else 1.0)
            if ai_roll(ctx.frame, f.bumper_pos.x, f.bumper_pos.z, 4.0) < (1.0 - f.ai_aggr) * (1.2 if hurt else 0.7) {
                f.ai_state = 2 // RETREAT
                f.ai_t = 0.7
            }
        }
    }
    if dist > 0.01 { f.yaw = math.atan2(to_f.x, to_f.z) }
}

combat_attack_trigger :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx) {
    sh := ctx.sh
    dt := ctx.dt
    bi := ctx.bi
        // attack trigger: J slash / K kick (auto: proximity+440 slash, 300 kick),
        // dummy slashes on AI range in manual play only
        prox := false
        if foe != nil {
            pd := foe.bumper_pos - f.bumper_pos
            prox = math.sqrt(pd.x * pd.x + pd.z * pd.z) < 2.4
        }
        want_kind := 0 // 0 none, 1 slash, 2 kick
        // guard: hold Shift (player) to block. Rooted: no attacks, slow
        // shuffle, no jump. AI raises guard on telegraphed swings (manual).
        f.blocking = false
        f.sneaking = false
        if f.stagger_t > 0 { f.stagger_t -= dt } // flinch burns down
        if f.mode == .Anim && f.grounded && f.stagger_t <= 0 && f.roll_t <= 0 && (f.atk_anim == nil || f.atk_t >= f.atk_dur) {
            if f.is_player {
                if (rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) || pad_guard_down()) && f.grabbed_by == nil && f.grab_victim == nil && f.carry_idx < 0 { f.blocking = true }
                if rl.IsKeyDown(.C) || pad_sneak_down() { f.sneaking = true } // low and quiet
            } else if (ctx.brains || !ctx.auto) && foe != nil && foe.mode == .Anim {
                // reaction: foe mid-windup, in range, facing us.
                // Sneaking foes read late and close (dull senses).
                react_frac := f32(0.22) if foe.sneaking else f32(0.35)
                react_rng := f32(1.8) if foe.sneaking else f32(3.2)
                if foe.atk_anim != nil && !foe.struck && foe.atk_t < react_frac * foe.atk_dur {
                    to_f := foe.bumper_pos - f.bumper_pos
                    dd := math.sqrt(to_f.x * to_f.x + to_f.z * to_f.z)
                    if dd < react_rng && dd > 1e-4 {
                        fd := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
                        if (to_f.x * fd.x + to_f.z * fd.z) / dd > 0.2 {
                            // deterministic roll (demo-stable), latched
                            h := f32(math.abs(math.sin(f32(ctx.frame) * 0.37 + f.bumper_pos.x * 1.7 + f.bumper_pos.z * 2.3)) * 7.0)
                            h = h - math.floor(h)
                            brave := f32(0.45) if f.kicks else f32(0.30)
                            if h < brave { f.block_t = 0.35 }
                        }
                    }
                }
            }
        }
        if f.block_t > 0 {
            f.block_t -= dt
            if f.mode == .Anim && f.grounded && f.grabbed_by == nil && f.grab_victim == nil && f.carry_idx < 0 { f.blocking = true }
        }
        if f.blocking { f.block_age += dt } else { f.block_age = 0 }
        if f.is_player {
            mash := rl.IsKeyPressed(.J) || rl.IsKeyPressed(.K) || rl.IsKeyPressed(.G) || rl.IsKeyPressed(.E) || rl.IsKeyPressed(.F) || rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) || g_pad.rt || g_pad.lt || pad_throw() || pad_pickup() || pad_grab()
            if f.grabbed_by != nil {
                if mash { // mash out: shove off, no punish
                    h := f.grabbed_by
                    away := f.bumper_pos - h.bumper_pos; away.y = 0
                    if al := linalg.length(away); al > 1e-4 { f.bumper_vel = away / al * 3.0 }
                    grab_release(f)
                    if ctx.auto { fmt.printf("f=%d BREAKS %s\n", ctx.frame, f.name) }
                }
            } else if f.grab_victim != nil || f.carry_idx >= 0 {
                if mash {
                    // hands full: any attack throws whatever you're holding
                    if f.grab_victim != nil { combat_throw_victim(f, ctx) }
                    else { combat_hurl_crate(f, ctx) }
                }
            } else if rl.IsKeyPressed(.F) || pad_grab() { combat_try_grab(f, foe, ctx) } // F grabs
            else if rl.IsKeyPressed(.J) || rl.IsMouseButtonPressed(.LEFT) || g_pad.rt { want_kind = 1 } // RT slashes
            else if rl.IsKeyPressed(.K) || rl.IsMouseButtonPressed(.RIGHT) || g_pad.lt { want_kind = 2 } // LT kicks
            else if rl.IsKeyPressed(.G) || pad_throw() { want_kind = 3 } // throw the sword
            else if rl.IsKeyPressed(.E) || pad_pickup() {
                // E takes steel if you're bare-handed, else lifts a crate
                if f.has_sword || !combat_try_pickup(f, ctx) { combat_try_lift(f, ctx) }
            }
            else if ctx.auto && ctx.frame == 440 { want_kind = 1 }
            else if ctx.auto && ctx.frame == 300 { want_kind = 2 }
            else if ctx.auto && ctx.frame == 318 { want_kind = 1 } // chain test
            else if ctx.auto && prox { want_kind = 1 }
        } else if (ctx.brains || !ctx.auto) && foe != nil && foe.mode == .Anim {
            // brain ordered a swing (range + cooldown + personality)
            want_kind = f.ai_want
            f.ai_want = 0
        }
        // cancel window: after contact, J/K chains mid-recover (combo);
        // whiffs must play out. AI chains through the same gate.
        // No attacking out of guard, none while staggered, none while held,
        // and holders throw instead of swinging (handled above).
        if f.blocking || f.stagger_t > 0 || f.grabbed_by != nil { want_kind = 0 }
        // death performance ends in a ragdoll handoff (mild carry, collapse)
        if f.dying && f.atk_anim != nil && f.atk_t >= min(f.atk_dur, 0.85) {
            f.dying = false
            hv := f.death_hv
            fighter_handoff(f, bi, hv, false)
            fmt.printf("f=%d FELL\n", ctx.frame)
        }
        can_cancel := f.connected && f.atk_anim != nil && f.atk_t >= 0.35 * f.atk_dur && f.atk_t < f.atk_dur
        if want_kind == 3 && (f.atk_t >= f.atk_dur || can_cancel) {
            combat_try_throw(f, ctx) // huck steel (no anim track of its own)
        } else if want_kind > 0 && want_kind < 3 && (f.atk_t >= f.atk_dur || can_cancel) {
            chained := f.atk_t < f.atk_dur
            f.atk_anim = sh.slash if want_kind == 1 else sh.kick
            f.atk_dur = sh.slash_dur if want_kind == 1 else sh.kick_dur
            f.atk_kick = want_kind == 2
            f.atk_t = 0
            f.struck = false
            f.connected = false
            f.sneak_atk = f.sneaking // the strike came from stealth (or not)
            if !f.grounded && want_kind == 2 {
                // flying kick carries: lunge along facing (dive keeps falling)
                f.bumper_vel += [3]f32{math.sin(f.yaw) * 3.5, 0, math.cos(f.yaw) * 3.5}
            }
            sfx_playi(SFXW_WHOOSH) // every swing starts with air
            if ctx.auto || f.is_player {
                fmt.printf("f=%d %s %s %s\n", ctx.frame, "CHAIN" if chained else "ATTACK", f.name, "slash" if want_kind == 1 else "kick")
            }
        }
}

// ---- disarm + pickup ----
// Swords knock loose on counters, heavies and death; they clatter down
// and anyone unarmed can take them back with E.
DroppedSword :: struct {
    active: bool,
    pos:    [3]f32,
    yaw:    f32,
    mesh:   rl.Mesh,
    mat:    rl.Material,
    thrown: bool,     // flying: spins, hits, sticks (else lying still)
    vel:    [3]f32,
    life:   f32,
    self:   ^Fighter, // who threw it (no self-hits, no teammates)
}
g_drops: [6]DroppedSword

combat_drop_sword :: proc(foe: ^Fighter, ctx: ^Ctx) {
    if !foe.has_sword || foe.sword_idx < 0 || foe.sword_idx >= len(foe.prims) { return }
    for &d in g_drops {
        if d.active { continue }
        d.active = true
        d.mesh = foe.prims[foe.sword_idx].mesh // shares GPU buffers
        d.mat = foe.prims[foe.sword_idx].mat
        fw := [3]f32{math.sin(foe.yaw), 0, math.cos(foe.yaw)}
        d.pos = foe.bumper_pos + fw * 0.7
        if gy, ok := ground_at(ctx.hf, d.pos.x, d.pos.z, d.pos.y + 1.0); ok {
            d.pos.y = gy + 0.12
        }
        d.yaw = foe.yaw + 0.6
        break
    }
    foe.has_sword = false
    sfx_playi(SFXW_BLOCK) // steel ring on the dirt
    feet := [3]f32{foe.bumper_pos.x, foe.bumper_pos.y + 0.2, foe.bumper_pos.z}
    parts_burst(&g_parts, feet, 5, 0.35, 0.1, DUST, 0.8)
}

combat_try_throw :: proc(f: ^Fighter, ctx: ^Ctx) {
    if !f.has_sword || f.sword_idx < 0 || f.sword_idx >= len(f.prims) { return }
    hurled := false
    for &d in g_drops {
        if d.active { continue }
        d.active = true
        d.thrown = true
        d.mesh = f.prims[f.sword_idx].mesh // shares GPU buffers
        d.mat = f.prims[f.sword_idx].mat
        fw := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
        d.pos = f.bumper_pos + [3]f32{0, 1.3, 0} + fw * 0.6
        d.vel = fw * 18.0 + [3]f32{0, 1.5, 0}
        d.yaw = f.yaw
        d.life = 0
        d.self = f
        hurled = true
        break
    }
    if !hurled { return } // rack's full: keep your steel
    f.has_sword = false
    // reads as an overhead slash that never connects (no double-dip)
    f.atk_anim = ctx.sh.slash
    f.atk_dur = ctx.sh.slash_dur
    f.atk_kick = false
    f.atk_t = 0
    f.struck = true
    f.connected = false
    sfx_playi(SFXW_WHOOSH)
    noise_push(f.bumper_pos, 8.0, ctx.frame)
    if ctx.auto || f.is_player { fmt.printf("f=%d THROW %s\n", ctx.frame, f.name) }
}

// thrown steel, stepped each sim frame: spins, wounds foes (2 dmg +
// stagger, lethal kills), else sticks in dirt/mass or expires to a drop
drops_update_thrown :: proc(ctx: ^Ctx, card: [4]^Fighter) {
    dt := ctx.dt
    for &d in g_drops {
        if !d.active || !d.thrown { continue }
        d.life += dt
        d.pos += d.vel * dt
        d.vel.y -= 9.0 * dt
        d.yaw += 12.0 * dt
        for i in 0 ..< 4 {
            v := card[i]
            if v == d.self || v.team == d.self.team || v.hp <= 0 || v.mode != .Anim { continue }
            dx := v.bumper_pos.x - d.pos.x
            dy := (v.bumper_pos.y + 1.0) - d.pos.y
            dz := v.bumper_pos.z - d.pos.z
            if dx * dx + dy * dy + dz * dz < 1.44 {
                v.hp -= 2
                if v.hp <= 0 {
                    combat_kill(v, ctx, d.vel * 0.1)
                } else {
                    hv := linalg.length([3]f32{d.vel.x, 0, d.vel.z})
                    dn := [3]f32{d.vel.x / max(hv, 1e-4), 0, d.vel.z / max(hv, 1e-4)}
                    combat_stagger(v, ctx, dn)
                    v.flash_t = 0.12
                    chest := v.bumper_pos + [3]f32{0, 1.2, 0}
                    parts_burst(&g_parts, chest, 8, 0.3, 0.09, SPARK, 1.0)
                    parts_burst(&g_parts, chest, 5, 0.45, 0.11, BLOOD, 0.8)
                    ctx.hitstop_f = max(ctx.hitstop_f, 3)
                    fmt.printf("f=%d HIT %s hp=%d\n", ctx.frame, v.name, v.hp)
                }
                d.thrown = false
                if gy, ok := ground_at(ctx.hf, d.pos.x, d.pos.z, d.pos.y + 1.0); ok {
                    d.pos.y = gy + 0.12
                }
                break
            }
        }
        if d.thrown {
            if gy, ok := ground_at(ctx.hf, d.pos.x, d.pos.z, d.pos.y + 0.5); ok && d.pos.y <= gy + 0.08 {
                d.thrown = false // stuck in the dirt
                d.pos.y = gy + 0.12
                noise_push(d.pos, 10.0, ctx.frame) // steel clatters: heads turn
            } else if arena_point_blocked(d.pos) {
                d.thrown = false // stuck in the mass
                noise_push(d.pos, 10.0, ctx.frame)
            } else if d.life > 1.6 {
                d.thrown = false // spent: clatter down below
                if gy2, ok2 := ground_at(ctx.hf, d.pos.x, d.pos.z, d.pos.y + 1.0); ok2 {
                    d.pos.y = gy2 + 0.12
                } else {
                    d.active = false
                }
                if d.active { noise_push(d.pos, 10.0, ctx.frame) }
            }
        }
    }
}
combat_try_pickup :: proc(f: ^Fighter, ctx: ^Ctx) -> bool {
    if f.has_sword || f.mode != .Anim || !f.grounded { return false }
    best := -1
    best_d := f32(1.5)
    for d, i in g_drops {
        if !d.active { continue }
        dd := linalg.length(d.pos - f.bumper_pos)
        if dd < best_d { best_d = dd; best = i }
    }
    if best < 0 { return false }
    g_drops[best].active = false
    f.has_sword = true
    sfx_playi(SFXW_UI)
    fmt.printf("f=%d PICKUP %s\n", ctx.frame, f.name)
    return true
}

// offensive grab: latch a standing foe (drag slow, throw with a swing
// key). Victims struggle free in 1.2s; mashing out costs the attempt.
grab_release :: proc(f: ^Fighter) {
    if f.grab_victim != nil {
        f.grab_victim.grabbed_by = nil
        f.grab_victim = nil
    }
    if f.grabbed_by != nil {
        f.grabbed_by.grab_victim = nil
        f.grabbed_by = nil
    }
}
combat_try_grab :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx) {
    if foe == nil || f.grab_victim != nil || f.grabbed_by != nil || f.carry_idx >= 0 { return }
    if f.mode != .Anim || !f.grounded || foe.mode != .Anim || !foe.grounded { return }
    if foe.hp <= 0 || foe.grabbed_by != nil || foe.hanging { return }
    dx := foe.bumper_pos.x - f.bumper_pos.x
    dz := foe.bumper_pos.z - f.bumper_pos.z
    if math.sqrt(dx * dx + dz * dz) > 2.2 { return }
    f.grab_victim = foe
    foe.grabbed_by = f
    foe.hold_t = 1.2
    foe.blocking = false
    foe.atk_t = foe.atk_dur // grabbed out of your swing
    foe.bumper_vel = {0, 0, 0}
    sfx_playi(SFXW_WHOOSH)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d GRABBED %s\n", ctx.frame, foe.name)
    }
}
combat_throw_victim :: proc(f: ^Fighter, ctx: ^Ctx) {
    v := f.grab_victim
    if v == nil { return }
    fwd := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
    hv := fwd * 7.0 + [3]f32{0, 4.5, 0}
    v.hp -= 1 // the throw itself bruises (landing adds fall damage)
    grab_release(f)
    if v.hp <= 0 {
        combat_kill(v, ctx, hv * 0.15)
    } else {
        fighter_handoff(v, ctx.bi, hv, true)
        combat_drop_sword(v, ctx) // hard throws knock steel loose
    }
    sfx_playi(SFXW_THUD)
    noise_push(f.bumper_pos, 12.0, ctx.frame)
    ctx.hitstop_f = max(ctx.hitstop_f, 3)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d THREW %s hp=%d\n", ctx.frame, v.name, v.hp)
    }
}

// ---- crate lift/carry/hurl (Overgrowth's favorite argument) ----
// Crates ride overhead kinematic; hurled ones go dynamic and wound the
// first fighter they meet (no self-hits for 30 frames). Hands full:
// swings throw instead, guards wait.
crate_state: [6]int      // 0 idle, 1 carried, 2 thrown
crate_holder: [6]^Fighter // carrier, or thrower until spent
crate_throw_f: [6]int
crate_pos :: proc(ctx: ^Ctx, ci: int) -> [3]f32 {
    cp: jph.RVec3
    jph.BodyInterface_GetPosition(ctx.bi, ctx.crate_ids[ci], &cp)
    return {cp.x, cp.y, cp.z}
}
crate_drop :: proc(f: ^Fighter, ctx: ^Ctx) {
    ci := f.carry_idx
    if ci < 0 || ci >= 6 { f.carry_idx = -1; return }
    if crate_state[ci] == 1 && crate_holder[ci] == f {
        jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[ci], .Dynamic, .Activate)
        zv := jph.Vec3{0, 0, 0}
        jph.BodyInterface_SetLinearVelocity(ctx.bi, ctx.crate_ids[ci], &zv)
        crate_state[ci] = 0
        crate_holder[ci] = nil
    }
    f.carry_idx = -1
}
combat_try_lift :: proc(f: ^Fighter, ctx: ^Ctx) {
    if f.carry_idx >= 0 || f.grab_victim != nil || f.grabbed_by != nil { return }
    if f.mode != .Anim || !f.grounded { return }
    best := -1
    best_d := f32(2.2)
    for ci in 0 ..< 6 {
        if crate_state[ci] != 0 { continue }
        dd := linalg.length(crate_pos(ctx, ci) - (f.bumper_pos + [3]f32{0, 1.0, 0}))
        if dd < best_d { best_d = dd; best = ci }
    }
    if best < 0 { return }
    crate_state[best] = 1
    crate_holder[best] = f
    f.carry_idx = best
    jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[best], .Kinematic, .Activate)
    sfx_playi(SFXW_WHOOSH)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d LIFT %s crate=%d\n", ctx.frame, f.name, best)
    }
}
combat_hurl_crate :: proc(f: ^Fighter, ctx: ^Ctx) {
    ci := f.carry_idx
    if ci < 0 || ci >= 6 || crate_state[ci] != 1 { f.carry_idx = -1; return }
    fwd := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
    hv := fwd * 14.0 + [3]f32{0, 2.0, 0} // line drive, not a lob
    // release in front of the chest, clear of our own head (else the box
    // spawns buried in us and dies on the spot)
    rp := f.bumper_pos + [3]f32{fwd.x * 1.0, 1.2, fwd.z * 1.0}
    rpp := jph.RVec3{rp.x, rp.y, rp.z}
    qk: jph.Quat = 1
    jph.BodyInterface_SetPositionAndRotationWhenChanged(ctx.bi, ctx.crate_ids[ci], &rpp, &qk, .Activate)
    jv := jph.Vec3{hv.x, hv.y, hv.z}
    jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[ci], .Dynamic, .Activate)
    jph.BodyInterface_SetLinearVelocity(ctx.bi, ctx.crate_ids[ci], &jv)
    av := jph.Vec3{6.0, 0, 2.0}
    jph.BodyInterface_SetAngularVelocity(ctx.bi, ctx.crate_ids[ci], &av)
    crate_state[ci] = 2
    crate_throw_f[ci] = ctx.frame
    f.carry_idx = -1
    sfx_playi(SFXW_WHOOSH)
    noise_push(f.bumper_pos, 12.0, ctx.frame)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d HURL %s crate=%d\n", ctx.frame, f.name, ci)
    }
}
// carried crates ride overhead; thrown ones wound whoever they meet
crates_update :: proc(ctx: ^Ctx, card: [4]^Fighter) {
    for ci in 0 ..< 6 {
        cp0 := crate_pos(ctx, ci)
        if cp0.x != cp0.x || cp0.y != cp0.y || cp0.z != cp0.z {
            // NaN crate (buried in a mass edge): recycle to the stack
            gx := f32(ci % 3) * 1.0 - 1.0
            if gy, ok := ground_at(ctx.hf, gx, 12.5, 1e9); ok {
                rp := jph.RVec3{gx, gy + 0.4 + f32(ci / 3) * 0.85, 12.5}
                qk: jph.Quat = 1
                jph.BodyInterface_SetPositionAndRotationWhenChanged(ctx.bi, ctx.crate_ids[ci], &rp, &qk, .Activate)
                zv := jph.Vec3{0, 0, 0}
                jph.BodyInterface_SetLinearVelocity(ctx.bi, ctx.crate_ids[ci], &zv)
            }
            jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[ci], .Dynamic, .Activate)
            crate_state[ci] = 0
            crate_holder[ci] = nil
            for f in card { if f.carry_idx == ci { f.carry_idx = -1 } }
            if ctx.auto { fmt.printf("f=%d CRATERECYCLE %d\n", ctx.frame, ci) }
            continue
        }
        if crate_state[ci] == 0 {
            // idle-heal: anything left kinematic (respawn drops) goes dynamic
            if jph.BodyInterface_GetMotionType(ctx.bi, ctx.crate_ids[ci]) != .Dynamic {
                jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[ci], .Dynamic, .Activate)
            }
            continue
        }
        if crate_state[ci] == 1 {
            h := crate_holder[ci]
            if h == nil || h.carry_idx != ci || h.mode != .Anim || h.hp <= 0 {
                if h != nil { h.carry_idx = -1 }
                crate_state[ci] = 0
                crate_holder[ci] = nil
                jph.BodyInterface_SetMotionType(ctx.bi, ctx.crate_ids[ci], .Dynamic, .Activate)
                continue
            }
            tp := h.bumper_pos + [3]f32{0, 2.6, 0}
            tpp := jph.RVec3{tp.x, tp.y, tp.z}
            qk: jph.Quat = 1
            jph.BodyInterface_MoveKinematic(ctx.bi, ctx.crate_ids[ci], &tpp, &qk, ctx.dt)
        } else if crate_state[ci] == 2 {
            cv: jph.Vec3
            jph.BodyInterface_GetLinearVelocity(ctx.bi, ctx.crate_ids[ci], &cv)
            spd := math.sqrt(cv.x * cv.x + cv.y * cv.y + cv.z * cv.z)
            if spd < 1.5 {
                crate_state[ci] = 0 // spent: an ordinary crate again
                crate_holder[ci] = nil
                continue
            }
            cp := crate_pos(ctx, ci)
            for i in 0 ..< 4 {
                v := card[i]
                if v.hp <= 0 || v.mode != .Anim { continue }
                if v == crate_holder[ci] && ctx.frame - crate_throw_f[ci] < 30 { continue }
                dx := v.bumper_pos.x - cp.x
                dy := (v.bumper_pos.y + 1.0) - cp.y
                dz := v.bumper_pos.z - cp.z
                if dx * dx + dy * dy + dz * dz < 3.24 { // 1.8m: catches head-high passes off the body wall
                    v.hp -= 2
                    if v.hp <= 0 {
                        combat_kill(v, ctx, {cv.x * 0.1, 2.0, cv.z * 0.1})
                    } else {
                        dn := [3]f32{cv.x / max(spd, 1e-4), 0, cv.z / max(spd, 1e-4)}
                        hv := dn * 6.0 + [3]f32{0, 4.5, 0}
                        fighter_handoff(v, ctx.bi, hv, true)
                        combat_drop_sword(v, ctx)
                    }
                    v.flash_t = 0.12
                    chest := v.bumper_pos + [3]f32{0, 1.2, 0}
                    parts_burst(&g_parts, chest, 10, 0.35, 0.1, SPARK, 1.2)
                    parts_burst(&g_parts, chest, 8, 0.5, 0.12, DUST, 1.4)
                    ctx.hitstop_f = max(ctx.hitstop_f, 4)
                    ctx.shake = max(ctx.shake, 0.35)
                    sfx_playi(SFXW_THUD)
                    crate_state[ci] = 0
                    crate_holder[ci] = nil
                    fmt.printf("f=%d CRATEHIT %s hp=%d\n", ctx.frame, v.name, v.hp)
                    break
                }
            }
        }
    }
}

// thrown bodies bowl pins: a fast ragdoll wounds standing foes it meets
// (no teammates). Pins scatter slow (no chains); kill-credit is ambient.
ragdoll_impacts :: proc(ctx: ^Ctx, card: [4]^Fighter) {
    for i in 0 ..< 4 {
        f := card[i]
        if f.mode != .Ragdoll || f.hp <= 0 { continue }
        bv: jph.Vec3
        jph.BodyInterface_GetLinearVelocity(ctx.bi, f.rb_ids[0], &bv)
        spd := math.sqrt(bv.x * bv.x + bv.y * bv.y + bv.z * bv.z)
        if spd < 7.0 { continue }
        bp: jph.RVec3
        jph.BodyInterface_GetPosition(ctx.bi, f.rb_ids[0], &bp)
        for j in 0 ..< 4 {
            if i == j { continue }
            v := card[j]
            if v.team == f.team || v.hp <= 0 || v.mode != .Anim { continue }
            dx := v.bumper_pos.x - bp.x
            dy := (v.bumper_pos.y + 1.0) - bp.y
            dz := v.bumper_pos.z - bp.z
            if dx * dx + dy * dy + dz * dz < 2.25 {
                v.hp -= 1
                if v.hp <= 0 {
                    combat_kill(v, ctx, {bv.x * 0.05, 2.0, bv.z * 0.05})
                } else {
                    hv := [3]f32{bv.x * 0.4, 0, bv.z * 0.4} + [3]f32{0, 3.0, 0}
                    fighter_handoff(v, ctx.bi, hv, true)
                    combat_drop_sword(v, ctx)
                }
                v.flash_t = 0.12
                chest := v.bumper_pos + [3]f32{0, 1.2, 0}
                parts_burst(&g_parts, chest, 8, 0.4, 0.1, DUST, 1.2)
                ctx.hitstop_f = max(ctx.hitstop_f, 2)
                sfx_playi(SFXW_THUD)
                fmt.printf("f=%d BODYHIT %s hp=%d\n", ctx.frame, v.name, v.hp)
                break
            }
        }
    }
}

// ---- dismemberment (Overgrowth's signature flourish) ----
// Lethal sword slashes with overkill (or from above/behind) sever: the
// victim's verts dominated by the cut subtree become a ballistic textured
// prop, the stump verts park on the sever joint in render (per-prim
// branch, zero hot-loop cost — the skeleton keeps animating underneath,
// so ragdoll corpses track). Kicks never sever (fists don't dismember).
Severed :: struct {
    mesh: rl.Mesh, mat: rl.Material, active: bool,
    verts, nrms, uvs: []f32, // owned (freed on ring-overwrite/clear)
    pos, vel: [3]f32, yaw, spin: f32,
}
g_limbs: [8]Severed
g_limb_next: int
g_severs: int // limbs taken this match (menu stats)

combat_sever :: proc(foe: ^Fighter, ctx: ^Ctx, atk: ^Fighter, dn: [3]f32, drop, temp_force: bool) -> bool {
    if !atk.has_sword { return false }
    overkill := -(foe.hp) // hp already reduced at the call site
    if !(temp_force || overkill >= 2 || !foe.grounded || drop) { return false }
    // head if the steel comes from above the neck, else the strike-side arm
    name := "mixamorig:LeftArm"
    head := false
    if atk.bumper_pos.y + 1.2 > foe.bumper_pos.y + 1.6 { name = "mixamorig:Head"; head = true }
    else {
        rv := [3]f32{math.cos(foe.yaw), 0, -math.sin(foe.yaw)} // victim right
        if dn.x * rv.x + dn.z * rv.z > 0 { name = "mixamorig:RightArm" }
    }
    sn := find_node(foe.data, name)
    if sn < 0 { return false }
    // palette set: joints whose node sits in the severed subtree
    in_sev := make([]bool, foe.nj)
    defer delete(in_sev)
    for j in 0 ..< foe.nj {
        n := foe.joint_node[j]
        for n >= 0 {
            if n == sn { in_sev[j] = true; break }
            n = parent_of(foe.data, n)
        }
    }
    mm := foe.render_mm
    cut_m := [3]f32{foe.world[sn][12], foe.world[sn][13], foe.world[sn][14]}
    cut_w := [3]f32{
        mm[0]*cut_m.x + mm[4]*cut_m.y + mm[8]*cut_m.z + mm[12],
        mm[1]*cut_m.x + mm[5]*cut_m.y + mm[9]*cut_m.z + mm[13],
        mm[2]*cut_m.x + mm[6]*cut_m.y + mm[10]*cut_m.z + mm[14],
    }
    made := false
    for &pr, pi in foe.prims {
        if !pr.skinned || pi == foe.sword_idx || len(pr.idx) == 0 { continue }
        dom := make([]bool, pr.count)
        defer delete(dom)
        sev_list := make([dynamic]int)
        defer delete(sev_list)
        for i in 0 ..< pr.count {
            best_j, best_w := -1, f32(-1)
            for k in 0 ..< 4 {
                if pr.weights[i][k] > best_w { best_w = pr.weights[i][k]; best_j = int(pr.joints[i][k]) }
            }
            if best_j >= 0 && best_j < foe.nj && in_sev[best_j] {
                dom[i] = true
                append(&sev_list, i)
            }
        }
        if len(sev_list) == 0 { continue }
        // triangle soup: tris with >= 2 severed corners fly, slivers stay
        sv := make([dynamic]f32); defer delete(sv)
        snn := make([dynamic]f32); defer delete(snn)
        suv := make([dynamic]f32); defer delete(suv)
        ntri := len(pr.idx) / 3
        for t in 0 ..< ntri {
            c0 := int(pr.idx[t*3]); c1 := int(pr.idx[t*3+1]); c2 := int(pr.idx[t*3+2])
            if c0 >= pr.count || c1 >= pr.count || c2 >= pr.count { continue }
            n := 0
            if dom[c0] { n += 1 }
            if dom[c1] { n += 1 }
            if dom[c2] { n += 1 }
            if n < 2 { continue }
            corners := [3]int{c0, c1, c2}
            for c in corners {
                mx := pr.dst[c*3]; my := pr.dst[c*3+1]; mz := pr.dst[c*3+2]
                append(&sv, mm[0]*mx + mm[4]*my + mm[8]*mz + mm[12],
                    mm[1]*mx + mm[5]*my + mm[9]*mz + mm[13],
                    mm[2]*mx + mm[6]*my + mm[10]*mz + mm[14])
                nx := pr.dstn[c*3]; ny := pr.dstn[c*3+1]; nz := pr.dstn[c*3+2]
                il := 1.0 / max(math.sqrt(nx*nx + ny*ny + nz*nz), 1e-6)
                append(&snn, (mm[0]*nx + mm[4]*ny + mm[8]*nz) * il,
                    (mm[1]*nx + mm[5]*ny + mm[9]*nz) * il,
                    (mm[2]*nx + mm[6]*ny + mm[10]*nz) * il)
                append(&suv, pr.uv[c*2], pr.uv[c*2+1])
            }
        }
        if len(sv) > 0 {
            nv := len(sv) / 3
            verts := make([]f32, nv * 3); copy(verts, sv[:])
            nrms := make([]f32, nv * 3); copy(nrms, snn[:])
            uvs := make([]f32, nv * 2); copy(uvs, suv[:])
            mesh := rl.Mesh{
                vertexCount = c.int(nv), triangleCount = c.int(nv / 3),
                vertices = raw_data(verts), texcoords = raw_data(uvs),
                normals = raw_data(nrms),
            }
            rl.UploadMesh(&mesh, false)
            slot := &g_limbs[g_limb_next]
            g_limb_next = (g_limb_next + 1) % 8
            if slot.active {
                rl.UnloadMesh(slot.mesh)
                delete(slot.verts); delete(slot.nrms); delete(slot.uvs)
            }
            slot.mesh = mesh; slot.mat = pr.mat; slot.active = true
            slot.verts = verts; slot.nrms = nrms; slot.uvs = uvs
            slot.pos = cut_w
            slot.vel = dn * 6.0 + [3]f32{0, 3.0, 0}
            slot.yaw = atk.yaw; slot.spin = 7.0
            made = true
        }
        // stump: park severed verts on the joint (rides anim + ragdoll)
        pr.sev_node = sn
        if pr.sev_idx != nil { delete(pr.sev_idx) }
        pr.sev_idx = make([]int, len(sev_list))
        copy(pr.sev_idx, sev_list[:])
    }
    if !made { return false }
    parts_burst(&g_parts, cut_w, 12, 0.5, 0.12, BLOOD, 1.4)
    if gy, ok := ground_at(ctx.hf, cut_w.x, cut_w.z, cut_w.y + 1.0); ok {
        decal_stamp(cut_w.x, cut_w.z, gy, 0.5)
    }
    if head { bark_say(ctx, "horn", "DECAPITATED") }
    g_severs += 1
    if ctx.auto || atk.is_player {
        fmt.printf("f=%d SEVER %s %s\n", ctx.frame, foe.name, "head" if head else "arm")
    }
    return true
}

limbs_update :: proc(ctx: ^Ctx) {
    for &l in g_limbs {
        if !l.active { continue }
        if l.vel.x != 0 || l.vel.y != 0 || l.vel.z != 0 {
            l.vel.y -= 18.0 * ctx.dt
            l.pos += l.vel * ctx.dt
            l.yaw += l.spin * ctx.dt
            if gy, ok := ground_at(ctx.hf, l.pos.x, l.pos.z, l.pos.y + 0.5); ok {
                if l.pos.y <= gy + 0.06 {
                    l.pos.y = gy + 0.06
                    l.vel = {0, 0, 0}; l.spin = 0
                }
            }
        }
    }
}

limbs_render :: proc() {
    for &l in g_limbs {
        if !l.active { continue }
        c, s := math.cos(l.yaw), math.sin(l.yaw)
        mm: [16]f32 = {c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, l.pos.x, l.pos.y, l.pos.z, 1}
        rl.DrawMesh(l.mesh, l.mat, to_rl(mm))
    }
}

limbs_clear :: proc() {
    for &l in g_limbs {
        if !l.active { continue }
        rl.UnloadMesh(l.mesh)
        delete(l.verts); delete(l.nrms); delete(l.uvs)
        l.active = false
    }
}

drops_render :: proc() {
    for &d in g_drops {
        if !d.active { continue }
        c, s := math.cos(d.yaw), math.sin(d.yaw)
        mm: [16]f32 = {c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, d.pos.x, d.pos.y, d.pos.z, 1}
        rl.DrawMesh(d.mesh, d.mat, to_rl(mm))
    }
}
combat_kill :: proc(foe: ^Fighter, ctx: ^Ctx, carry: [3]f32) {
    foe.hp = min(foe.hp, 0)
    if foe.is_player { bark_say(ctx, "horn", "YOU FALL") }
    else if foe.team == 0 { bark_say(ctx, "horn", "ALLY DOWN") }
    else { bark_say(ctx, "horn", "HUNTER DOWN") }
    foe.dying = true
    combat_drop_sword(foe, ctx) // the dead drop their steel
    noise_push(foe.bumper_pos, 20.0, ctx.frame) // everyone hears a kill
    foe.death_hv = carry
    chest := foe.bumper_pos + [3]f32{0, 1.0, 0}
    parts_burst(&g_parts, chest, 14, 0.6, 0.13, DUST, 1.8)
    parts_burst(&g_parts, chest, 8, 0.5, 0.11, BLOOD, 1.2)
    for i in 0 ..< 3 { // the kill soaks the dirt around the body
        ox := (f32(i) - 1.0) * 0.5
        oz := (f32((i + 1) % 3) - 1.0) * 0.5
        if gy, ok := ground_at(ctx.hf, foe.bumper_pos.x + ox, foe.bumper_pos.z + oz, foe.bumper_pos.y + 1.0); ok {
            decal_stamp(foe.bumper_pos.x + ox, foe.bumper_pos.z + oz, gy, 0.5)
        }
    }
    foe.atk_anim = ctx.sh.death
    foe.atk_dur = ctx.sh.death_dur
    foe.atk_t = 0
    foe.atk_kick = false
    foe.struck = true
    foe.connected = false
    foe.flash_t = 0.12
    ctx.hitstop_f = max(ctx.hitstop_f, 6)
    ctx.shake = max(ctx.shake, 0.5)
    sfx_playi(SFXW_KO) // the boom
    if foe.team == 1 { g_kos_you += 1 } else { g_kos_dummy += 1 }
    fmt.printf("f=%d K.O.! %s down (you %d - %d dummy)\n", ctx.frame, foe.name, g_kos_you, g_kos_dummy)
}

// light-hit flinch: victim stays standing (no ragdoll), loses 0.45s of
// offense+guard, takes a grounded shove. Kicks still ragdoll (heavy).
combat_stagger :: proc(foe: ^Fighter, ctx: ^Ctx, dn: [3]f32) {
    if foe.mode != .Anim {
        // slashing a limp body: keep it flying (light juggle refresh)
        hv := dn * 8.0 + [3]f32{0, 4.0, 0}
        fighter_handoff(foe, ctx.bi, hv, true)
        return
    }
    foe.stagger_t = 0.45
    foe.blocking = false
    grab_release(foe) // flinch shakes grabs loose (held or holding)
    crate_drop(foe, ctx) // and crates out of hands
    foe.atk_t = foe.atk_dur // flinch interrupts your swing (out-blend covers it)
    foe.bumper_vel += dn * 3.0
    foe.state = "hit"
}

combat_strike :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx) {
    bi := ctx.bi
    sh := ctx.sh
    if f.do_anim {
        if f.atk_anim != nil && f.atk_t < f.atk_dur {
            if f.atk_t >= 0.35 * f.atk_dur && !f.struck {
                f.struck = true
                fdir := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
                // strike the other fighter (damage only if it was standing; juggle otherwise)
                if foe != nil {
                    to := [3]f32{foe.bumper_pos.x - f.bumper_pos.x, foe.bumper_pos.y + 1.0 - (f.bumper_pos.y + 1.0), foe.bumper_pos.z - f.bumper_pos.z}
                    dist := linalg.length(to)
                    reach := f32(2.2) if f.atk_kick else (f32(3.4) if f.has_sword else f32(2.6))
                    if dist < reach && dist > 1e-4 {
                        dn := to / dist
                        if dn.x * fdir.x + dn.z * fdir.z > 0.15 {
                            // guard: foe standing, blocking, facing us ->
                            // negated + shoved, no handoff, no cancel for us
                            blocked := false
                            if foe.mode == .Anim && foe.blocking {
                                efd := [3]f32{math.sin(foe.yaw), 0, math.cos(foe.yaw)}
                                if efd.x * -dn.x + efd.z * -dn.z > 0.2 {
                                    blocked = true
                                }
                            }
                            // i-frames first (a dash avoids clean), then guard
                            if foe.dodge_t > 0 {
                                f.struck = true
                                if ctx.auto {
                                    fmt.printf("f=%d DODGED %s\n", ctx.frame, foe.name)
                                }
                            } else if blocked {
                                // counter: fresh guard turns the block into a
                                // throw (sneaking sharpens the window to 0.4s)
                                counter_win := f32(0.4) if foe.sneaking else f32(0.25)
                                if foe.block_age < counter_win && foe.mode == .Anim && !f.dying {
                                    back := -dn * 7.0 + [3]f32{0, 5.0, 0}
                                    fighter_handoff(f, bi, back, false)
                                    f.connected = false
                                    combat_drop_sword(f, ctx) // counters knock steel loose
                                    sfx_playi(SFXW_BLOCK)
                                    ctx.hitstop_f = max(ctx.hitstop_f, 6)
                                    ctx.shake = max(ctx.shake, 0.5)
                                    chest := f.bumper_pos + [3]f32{0, 1.2, 0}
                                    parts_burst(&g_parts, chest, 10, 0.35, 0.1, SPARK, 1.2)
                                    if ctx.auto || f.is_player {
                                        fmt.printf("f=%d COUNTER %s\n", ctx.frame, f.name)
                                    }
                                    f.struck = true
                                    return
                                }
                                f.struck = true
                                sfx_playi(SFXW_BLOCK) // guard clang
                                foe.bumper_pos.x += dn.x * 0.5
                                foe.bumper_pos.z += dn.z * 0.5
                                if ctx.auto || f.is_player {
                                    fmt.printf("f=%d BLOCKED %s\n", ctx.frame, foe.name)
                                }
                            } else {
                            was_up := foe.mode == .Anim
                            // assassination: struck from stealth with the victim
                            // facing away or never having seen you — bonus damage
                            // and they go down. Facing guard still stops it
                            // above; i-frames still avoid.
                            bonus := 0
                            drop := false
                            dropkick := false
                            if f.sneak_atk && was_up && foe.mode == .Anim {
                                efd2 := [3]f32{math.sin(foe.yaw), 0, math.cos(foe.yaw)}
                                // victim forward along attacker->victim = facing away
                                behind := efd2.x * dn.x + efd2.z * dn.z > f32(0.2)
                                lost := ctx.frame - foe.info_frame > 60
                                if behind || lost {
                                    bonus = 2
                                    drop = true
                                }
                            }
                            // drop kick: striking from well above, airborne —
                            // gravity does half the work (+1, kicks already drop)
                            if !f.grounded && was_up && foe.mode == .Anim && f.bumper_pos.y - foe.bumper_pos.y > 0.8 {
                                bonus += 1
                                dropkick = true
                            }
                            hv := dn * (4.0 if f.atk_kick else 8.0) + ([3]f32{0, 5.5, 0} if f.atk_kick else [3]f32{0, 4.0, 0})
                            if was_up && foe.hp > 0 && foe.hp - (f.dmg + bonus) <= 0 {
                                // lethal: death performance first (no instant
                                // launch), ragdoll handoff when it plays out
                                foe.hp -= (f.dmg + bonus)
                                // steel severs: overkill, airborne, or from behind
                                if !f.atk_kick {
                                    combat_sever(foe, ctx, f, dn, drop, false)
                                }
                                combat_kill(foe, ctx, hv * 0.15)
                            } else {
                            // heavy (kick) ragdolls; light (slash) staggers —
                            // assassination drops them either way
                            if f.atk_kick || drop {
                                fighter_handoff(foe, bi, hv, true)
                                combat_drop_sword(foe, ctx) // heavies knock steel loose
                                if bonus > 0 {
                                    foe.hp -= bonus // over the base dmg the tail lands
                                    if ctx.auto || f.is_player {
                                        if drop {
                                            fmt.printf("f=%d ASSASSIN %s hp=%d\n", ctx.frame, foe.name, foe.hp)
                                            bark_say(ctx, "horn", "SILENT KILL")
                                        } else if dropkick {
                                            fmt.printf("f=%d DROP %s hp=%d\n", ctx.frame, foe.name, foe.hp)
                                        }
                                    }
                                }
                            } else {
                                combat_stagger(foe, ctx, dn)
                                if dropkick {
                                    foe.hp -= bonus // drop slash still bruises deep
                                    if ctx.auto || f.is_player {
                                        fmt.printf("f=%d DROP %s hp=%d\n", ctx.frame, foe.name, foe.hp)
                                    }
                                }
                            }
                            f.connected = true // contact: cancel window opens
                            if f.atk_kick {
                                sfx_playi(SFXW_THUD)
                            } else {
                                sfx_playi(SFXW_HIT)
                            }
                            // impact feel: victim flashes, world freezes a
                            // beat, camera kicks (bigger for KOs)
                            foe.flash_t = 0.12
                            chest := foe.bumper_pos + [3]f32{0, 1.2, 0}
                            parts_burst(&g_parts, chest, 8, 0.3, 0.09, SPARK, 1.0)
                            parts_burst(&g_parts, chest, 5, 0.45, 0.11, BLOOD, 0.8)
                            if gy, ok := ground_at(ctx.hf, foe.bumper_pos.x, foe.bumper_pos.z, foe.bumper_pos.y + 1.0); ok {
                                decal_stamp(foe.bumper_pos.x, foe.bumper_pos.z, gy, 0.35)
                            }
                            noise_push(foe.bumper_pos, 12.0, ctx.frame) // steel rings out
                            ctx.hitstop_f = max(ctx.hitstop_f, 3)
                            ctx.shake = max(ctx.shake, 0.25)
                            // NOTE: lethal hits are handled above (death
                            // performance); here damage only if still alive
                            // (beating a dying body juggles, never double-KOs)
                            if was_up && foe.hp > 0 {
                                foe.hp -= f.dmg
                                grab_release(foe) // hard hits shake grabs loose (both sides)
                                grab_release(f)
                                crate_drop(foe, ctx) // and crates out of hands
                                crate_drop(f, ctx)
                                if !g_firstblood { g_firstblood = true; bark_say(ctx, "horn", "FIRST BLOOD"); sfx_playi(SFXW_STING) }
                                fmt.printf("f=%d HIT %s hp=%d\n", ctx.frame, foe.name, foe.hp)
                            } else {
                                fmt.printf("f=%d JUGGLE %s\n", ctx.frame, foe.name)
                            }
                            } // end lethal-else: non-lethal strike lands
                            } // end else (not blocked): full strike lands
                        }
                    }
                }
                // player also launches crates
                if f.is_player {
                    for ci in 0 ..< 6 {
                        cp: jph.RVec3
                        jph.BodyInterface_GetPosition(bi, ctx.crate_ids[ci], &cp)
                        to := [3]f32{cp.x - f.bumper_pos.x, cp.y - 1.0, cp.z - f.bumper_pos.z}
                        dist := linalg.length(to)
                        if dist < 2.4 && dist > 1e-4 {
                            dn := to / dist
                            if dn.x * fdir.x + dn.z * fdir.z > 0.2 {
                                kv := dn * (4.0 if f.atk_kick else 7.0) + ([3]f32{0, 5.5, 0} if f.atk_kick else [3]f32{0, 3.5, 0})
                                jv := jph.Vec3{kv.x, kv.y, kv.z}
                                jph.BodyInterface_SetMotionType(bi, ctx.crate_ids[ci], .Dynamic, .Activate)
                                jph.BodyInterface_SetLinearVelocity(bi, ctx.crate_ids[ci], &jv)
                                avx := f32(4.0) if ci % 2 == 0 else f32(-4.0)
                                av := jph.Vec3{avx, 0, 2.0}
                                jph.BodyInterface_SetAngularVelocity(bi, ctx.crate_ids[ci], &av)
                            }
                        }
                    }
                    if ctx.auto { fmt.printf("f=%d STRUCK\n", ctx.frame) }
                }
            }
        }
    }
}
