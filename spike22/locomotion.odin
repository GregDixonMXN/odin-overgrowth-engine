package spike22

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import rl "vendor:raylib"
import jph "../thirdparty/joltc-odin"
// spike22 locomotion: bumper sim, terrain stick, slope align, yaw; update driver.
// dodge trigger body: dash + i-frames + escape hatches + feedback
loco_dodge :: proc(f: ^Fighter, dir: [3]f32) {
    f.dodge_t = 0.22
    f.dodge_cd = 0.7
    grab_release(f) // dashing slips fingers (both sides)
    f.dodge_dir = dir
    f.tap_key = 0
    f.tap_t = 0
    f.stagger_t = 0
    if f.atk_anim != nil && !f.connected { f.atk_t = f.atk_dur }
    sfx_playi(SFXW_WHOOSH)
    feet := [3]f32{f.bumper_pos.x, f.bumper_pos.y + 0.15, f.bumper_pos.z}
    parts_burst(&g_parts, feet, 8, 0.4, 0.12, DUST, 1.0)
}
// ---- bumper ----
locomotion_bumper :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx, cam: ^rl.Camera3D) {
    bi := ctx.bi
    dt := ctx.dt
    if f.do_anim {
        fwd := [3]f32{cam.target.x - cam.position.x, 0, cam.target.z - cam.position.z}
        // camera exactly on its target (respawn snap, wall squeeze):
        // normalize would NaN the whole sim — fall back to facing
        if fwd.x * fwd.x + fwd.z * fwd.z < 1e-8 {
            fwd = [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
        } else {
            fwd = linalg.normalize(fwd)
        }
        right := [3]f32{-fwd.z, 0, fwd.x}
        accel := [3]f32{}
        if f.is_player {
            if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    { accel += fwd * f.accel_rate }
            if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  { accel -= fwd * f.accel_rate }
            if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) { accel += right * f.accel_rate }
            if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  { accel -= right * f.accel_rate }
            accel += fwd * (g_pad.move.y * f.accel_rate) // left stick (analog)
            accel += right * (g_pad.move.x * f.accel_rate)
            if ctx.auto { accel = fwd * f.accel_rate }
            if f.grabbed_by != nil { accel = {} } // held: no steering (mash out instead)
            if !ctx.auto {
                if f.tap_t > 0 { f.tap_t -= dt }
                if f.dodge_cd > 0 { f.dodge_cd -= dt }
                key, dir := 0, [3]f32{}
                if rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP)       { key, dir = 1, fwd }
                if rl.IsKeyPressed(.S) || rl.IsKeyPressed(.DOWN)     { key, dir = 2, -fwd }
                if rl.IsKeyPressed(.D) || rl.IsKeyPressed(.RIGHT)    { key, dir = 3, right }
                if rl.IsKeyPressed(.A) || rl.IsKeyPressed(.LEFT)     { key, dir = 4, -right }
                fk := g_pad.flick // stick flick taps the dodge window too
                if fk == 1 { key, dir = 1, fwd }
                else if fk == 2 { key, dir = 2, -fwd }
                else if fk == 3 { key, dir = 3, right }
                else if fk == 4 { key, dir = 4, -right }
                if key != 0 {
                    if key == f.tap_key && f.tap_t > 0 && f.grounded && f.dodge_cd <= 0 && !f.dying {
                        loco_dodge(f, dir)
                    } else {
                        f.tap_key = key
                        f.tap_t = 0.28
                    }
                }
                // RB: instant dodge toward the stick (facing if neutral)
                if pad_dodge() && f.grounded && f.dodge_cd <= 0 && !f.dying {
                    dd := [3]f32{right.x * g_pad.move.x + fwd.x * g_pad.move.y, 0, right.z * g_pad.move.x + fwd.z * g_pad.move.y}
                    if linalg.length(dd) < 0.2 {
                        dd = [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
                    }
                    loco_dodge(f, linalg.normalize(dd))
                }
            }
        } else if foe != nil && foe.mode == .Anim && (ctx.brains || !ctx.auto) {
            // v1 brain: chase / circle / retreat / strike (auto demo holds still)
            ai_drive(f, foe, ctx, &accel)
        }
        if f.roll_t > 0 {
            // roll: committed tumble, steering locked, momentum kept
            f.roll_t -= dt
            f.bumper_vel = f.bumper_vel * math.exp(-1.0 * dt)
            f.speed = linalg.length(f.bumper_vel)
        } else {
            f.bumper_vel += accel * dt
            if f.sneaking { f.bumper_vel *= math.exp(-4.0 * dt) } // crouch drag
            else { f.bumper_vel *= math.exp(-2.5 * dt) }
        }
        if f.dying {
            // death performance: no self-motion, slide to a stop
            f.bumper_vel *= math.exp(-8.0 * dt)
        }
        if f.blocking {
            // guard roots you: heavy shuffle, no jump
            f.bumper_vel *= math.exp(-6.0 * dt)
        }
        if f.stagger_t > 0 {
            // flinch: control mostly gone, shove decays fast
            f.bumper_vel *= math.exp(-6.0 * dt)
        }
        f.speed = linalg.length(f.bumper_vel)
        sneak_lim := f.top_speed * (0.35 if f.sneaking else 1.0)
        if f.speed > sneak_lim { f.bumper_vel *= sneak_lim / f.speed; f.speed = sneak_lim }
        if f.grab_victim != nil {
            // dragging a body: heavy shuffle (victim is dead weight)
            grab_lim := f.top_speed * 0.45
            if f.speed > grab_lim { f.bumper_vel *= grab_lim / f.speed; f.speed = grab_lim }
        }
        if f.carry_idx >= 0 {
            // crate overhead: loaded walk (lighter than a body)
            carry_lim := f.top_speed * 0.7
            if f.speed > carry_lim { f.bumper_vel *= carry_lim / f.speed; f.speed = carry_lim }
        }
        if f.dodge_t > 0 {
            // dash: fixed burst along the tapped direction, steering locked
            f.dodge_t -= dt
            f.bumper_vel = f.dodge_dir * f.top_speed * 2.3
            f.speed = f.top_speed * 2.3
        }
        if !f.sneaking { sfx_steps(f, dt) } // sneak is silent
        prev_x, prev_z := f.bumper_pos.x, f.bumper_pos.z
        f.bumper_pos += f.bumper_vel * dt
        if f.vault_cd > 0 { f.vault_cd -= dt }
        // arena sides: push out of building masses (hit/n feed vault)
        blocked := false
        hit_idx := -1
        wn := [3]f32{}
        {
            p2, h2, n2 := arena_pushout(f.bumper_pos, f.bumper_pos.y)
            f.bumper_pos = p2
            if h2 >= 0 { blocked = true; hit_idx = h2; wn = n2 }
        }
        if f.is_player {
            if rl.IsKeyPressed(.SPACE) || pad_jump_pressed() || (ctx.auto && ctx.frame == 100) {
                if f.hanging {
                    arena_hang_mount(f, ctx) // pull up off the lip
                } else if !f.grounded {
                    arena_try_walljump(f, ctx)
                } else if !f.blocking && !f.dying {
                    // vault first (SPACE at a low wall), else plain jump
                    if !(blocked && arena_try_vault(f, ctx, hit_idx, wn)) {
                        // jump-cancel: SPACE mid-recover-after-contact ends the attack
                        if f.atk_anim != nil && f.atk_t < f.atk_dur && f.connected {
                            f.atk_t = f.atk_dur
                        }
                        f.vy = 5.0; f.grounded = false; f.air_t = 0; f.roll_t = 0 // jump out of the roll
                        grab_release(f) // jumping slips fingers (both sides)
                    }
                }
            }
            if ctx.auto && blocked && f.grounded {
                arena_try_vault(f, ctx, hit_idx, wn) // demo climbs on contact
            }
        } else if !ctx.auto {
            // AI vaults obstacles while chasing (no jump button for brains)
            if blocked && foe != nil {
                to_foe := foe.bumper_pos - f.bumper_pos
                flat := linalg.length([3]f32{to_foe.x, 0, to_foe.z})
                if f.grounded {
                    if to_foe.y > 0.8 || flat < 6.0 {
                        arena_try_vault(f, ctx, hit_idx, wn) // climb/cutoff
                    }
                } else {
                    arena_try_walljump(f, ctx) // airborne at a wall: bounce
                }
            }
        }
        {
            // shared terrain locomotion: stick, step, wall-block, fall
            gy, ok := ground_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z, f.bumper_pos.y)
            if !ok { gy = -100.0 }
            if f.grounded {
                if gy - f.bumper_pos.y > 0.7 {
                    // wall: cancel the horizontal step, bleed speed
                    f.bumper_pos.x = prev_x; f.bumper_pos.z = prev_z
                    f.bumper_vel *= 0.2
                } else if f.bumper_pos.y - gy > 0.7 {
                    f.grounded = false; f.vy = 0; f.air_t = 0 // ran off a real drop
                } else {
                    f.bumper_pos.y = gy // stick (climb/descend smoothly)
                }
            }
            if !f.grounded {
                if f.hanging {
                    // lip hang: glued to the face, gravity off. Shimmy on
                    // A/D, SPACE mounts, S drops. AI pulls up after 0.5s.
                    ar := g_arena
                    if ar == nil || f.hang_box < 0 || f.hang_box >= len(ar.boxes) {
                        f.hanging = false
                    } else {
                        b := &ar.boxes[f.hang_box]
                        f.hang_t += dt
                        n := [3]f32{}
                        switch f.hang_face {
                        case 0: n = {-1, 0, 0}; f.bumper_pos.x = b.lo.x - 0.55
                        case 1: n = {1, 0, 0}; f.bumper_pos.x = b.hi.x + 0.55
                        case 2: n = {0, 0, -1}; f.bumper_pos.z = b.lo.z - 0.55
                        case 3: n = {0, 0, 1}; f.bumper_pos.z = b.hi.z + 0.55
                        }
                        f.vy = 0
                        f.yaw = math.atan2(-n.x, -n.z) // nose to the wall
                        if f.is_player && !ctx.auto {
                            shim := f32(0)
                            if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) { shim -= 1.5 * dt }
                            if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) { shim += 1.5 * dt }
                            shim += g_pad.move.x * 1.5 * dt // stick shimmies too
                            if f.hang_face < 2 {
                                f.bumper_pos.z = math.clamp(f.bumper_pos.z + shim * (f32(1) if f.hang_face == 0 else f32(-1)), b.lo.z, b.hi.z)
                            } else {
                                f.bumper_pos.x = math.clamp(f.bumper_pos.x + shim * (f32(1) if f.hang_face == 2 else f32(-1)), b.lo.x, b.hi.x)
                            }
                            if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) || g_pad.move.y < -0.7 {
                                f.hanging = false // let go
                                f.bumper_vel = n * 1.5
                            }
                        } else if !f.is_player && f.hang_t > 0.5 {
                            arena_hang_mount(f, ctx) // brains pull up
                        }
                    }
                } else {
                f.vy -= 14.0 * dt
                f.bumper_pos.y += f.vy * dt
                f.air_t += dt
                // lip catch: falling past a box edge, drifting in
                if !f.hanging && f.mode == .Anim && !f.dying {
                    if grab_bi, grab_face, grab_ok := arena_ledge_grab(f.bumper_pos, f.bumper_vel, f.vy); grab_ok {
                        f.hanging = true; f.hang_box = grab_bi; f.hang_face = grab_face; f.hang_t = 0
                        f.vy = 0
                        sfx_playi(SFXW_STEP2)
                        if ctx.auto || f.is_player {
                            fmt.printf("f=%d GRAB\n", ctx.frame)
                        }
                    }
                }
                gy2, ok2 := ground_at(ctx.hf, f.bumper_pos.x, f.bumper_pos.z, f.bumper_pos.y)
                if !ok2 { gy2 = -100.0 }
                if f.bumper_pos.y <= gy2 && f.vy <= 0 {
                    if f.air_t > 0.25 {
                        sfx_playi(SFXW_STEP2)
                        feet := [3]f32{f.bumper_pos.x, gy2 + 0.15, f.bumper_pos.z}
                        parts_burst(&g_parts, feet, 10, 0.5, 0.14, DUST, 1.4)
                    } // dust + thud
                    f.bumper_pos.y = gy2; f.grounded = true; f.vy = 0; f.land_t = 0.3; f.land_elapsed = 0
                    if ctx.auto { fmt.printf("f=%d LANDED\n", ctx.frame) }
                    // falling damage (OG): long drops hurt, huge ones kill.
                    // Fast survivors roll it out (half damage, committed
                    // tumble); slow ones stagger. Rolls can't save mega-drops.
                    if f.air_t > 0.9 && f.hp > 0 && !f.dying {
                        dmg := int((f.air_t - 0.9) * 5.0) + 1
                        rolling := f.speed > 3.5
                        if rolling { dmg = dmg / 2 }
                        f.hp -= dmg
                        if f.hp <= 0 {
                            combat_kill(f, ctx, {0, 0, 0})
                        } else if rolling {
                            f.roll_t = 0.55
                            f.blocking = false
                            sfx_playi(SFXW_WHOOSH)
                            feet := [3]f32{f.bumper_pos.x, gy2 + 0.15, f.bumper_pos.z}
                            parts_burst(&g_parts, feet, 14, 0.55, 0.15, DUST, 1.6)
                            noise_push(f.bumper_pos, 8.0, ctx.frame)
                            fmt.printf("f=%d ROLL %s hp=%d\n", ctx.frame, f.name, f.hp)
                        } else if f.air_t > 1.2 {
                            f.stagger_t = max(f.stagger_t, 0.3)
                            f.blocking = false
                            noise_push(f.bumper_pos, 10.0, ctx.frame)
                            fmt.printf("f=%d HARD LAND %s hp=%d\n", ctx.frame, f.name, f.hp)
                        }
                    }
                }
            } // end else (not hanging): normal airborne sim
            } // end if (!grounded): hanging + airborne share it
            // teleport guard: revert instant unflagged jumps (falls are
            // gradual; mounts only rise). NaN or >10m XZ, >5m down.
            if !f.tele_ok && f.prev_pos != {0, 0, 0} {
                if f.prev_pos.y - f.bumper_pos.y > 5.0 {
                    if ctx.auto { fmt.printf("f=%d YBLOCK %s %.1f->%.1f\n", ctx.frame, f.name, f.prev_pos.y, f.bumper_pos.y) }
                    f.bumper_pos.y = f.prev_pos.y
                    f.vy = 0
                }
                dx := f.bumper_pos.x - f.prev_pos.x
                dz := f.bumper_pos.z - f.prev_pos.z
                if f.bumper_pos.x != f.bumper_pos.x || f.bumper_pos.z != f.bumper_pos.z || dx > 10.0 || dx < -10.0 || dz > 10.0 || dz < -10.0 {
                    if ctx.auto { fmt.printf("f=%d XBLOCK %s\n", ctx.frame, f.name) }
                    f.bumper_pos.x = f.prev_pos.x
                    f.bumper_pos.z = f.prev_pos.z
                    f.bumper_vel.x = 0; f.bumper_vel.z = 0
                }
            }
            if f.bumper_pos.y < -60.0 && f.hp > 0 {
                // off the world: lose 1 HP, pop back (KO flow takes over at 0)
                if f.hp > 1 {
                    f.hp -= 1
                    sp := [3]f32{0, 0, 0}
                    if !f.is_player && foe != nil { sp = {foe.bumper_pos.x, 0, foe.bumper_pos.z + 4.0} }
                    if sy, ok2 := ground_at(ctx.hf, sp.x, sp.z, 1e9); ok2 { sp.y = sy }
                    fighter_recover(f, bi, sp, ctx.hf)
                    fmt.printf("f=%d FELL, hp=%d\n", ctx.frame, f.hp)
                } else {
                    f.hp = 0
                    if f.team == 1 { g_kos_you += 1 } else { g_kos_dummy += 1 }
                    fmt.printf("f=%d FELL OUT K.O.!\n", ctx.frame)
                }
            }
            // slope align: tilt model up toward the terrain normal (smoothed)
            s_fw := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
            s_rx := [3]f32{math.cos(f.yaw), 0, -math.sin(f.yaw)}
            ha, _ := ground_at(ctx.hf, f.bumper_pos.x + s_fw.x * 0.8, f.bumper_pos.z + s_fw.z * 0.8, f.bumper_pos.y)
            hb, _ := ground_at(ctx.hf, f.bumper_pos.x - s_fw.x * 0.8, f.bumper_pos.z - s_fw.z * 0.8, f.bumper_pos.y)
            hl, _ := ground_at(ctx.hf, f.bumper_pos.x + s_rx.x * 0.8, f.bumper_pos.z + s_rx.z * 0.8, f.bumper_pos.y)
            hr, _ := ground_at(ctx.hf, f.bumper_pos.x - s_rx.x * 0.8, f.bumper_pos.z - s_rx.z * 0.8, f.bumper_pos.y)
            dhf := math.clamp((ha - hb) / 1.6, -0.6, 0.6)
            dhs := math.clamp((hl - hr) / 1.6, -0.6, 0.6)
            uw := yaw_rot(linalg.normalize([3]f32{-dhs, 1, -dhf}), f.yaw)
            k := 1.0 - math.exp(-8.0 * dt)
            f.slope_up = linalg.normalize(f.slope_up * (1 - k) + uw * k)
        }
        if f.speed > 0.5 && (f.is_player || foe == nil) {
            // face travel direction only when moving forward-ish; S keeps
            // facing (true backpedal) and strafes don't spin the character
            // (or the yaw-following camera)
            fw := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
            if (f.bumper_vel.x * fw.x + f.bumper_vel.z * fw.z) / f.speed > 0.2 {
                f.yaw = math.atan2(f.bumper_vel.x, f.bumper_vel.z)
            }
        }
    combat_attack_trigger(f, foe, ctx)
        // bumper blocked by crates
        for ci in 0 ..< 6 {
            cp: jph.RVec3
            jph.BodyInterface_GetPosition(bi, ctx.crate_ids[ci], &cp)
            dx := f.bumper_pos.x - cp.x
            dz := f.bumper_pos.z - cp.z
            dy := 0.9 - cp.y
            d2 := dx * dx + dz * dz
            if d2 < 1.0 && d2 > 1e-8 && math.abs(dy) < 1.1 {
                d := math.sqrt(d2)
                push := (1.0 - d) / d
                f.bumper_pos.x += dx * push
                f.bumper_pos.z += dz * push
            }
        }
        // fighters push out of each other; a downed foe gets shoved aside (step over)
        if foe != nil {
            dx := f.bumper_pos.x - foe.bumper_pos.x
            dz := f.bumper_pos.z - foe.bumper_pos.z
            d2 := dx * dx + dz * dz
            if d2 < 1.0 && d2 > 1e-8 {
                d := math.sqrt(d2)
                push := (1.0 - d) / d * 0.5
                if foe.mode == .Ragdoll {
                    foe.bumper_pos.x -= dx * push * 2.0
                    foe.bumper_pos.z -= dz * push * 2.0
                } else {
                    f.bumper_pos.x += dx * push
                    f.bumper_pos.z += dz * push
                }
            }
        }
    }
}

// shared per-frame sim+pose for one fighter. foe may be nil.
fighter_update :: proc(f: ^Fighter, foe: ^Fighter, ctx: ^Ctx, cam: ^rl.Camera3D) {
    // position baseline for the teleport guard (all-zero = never synced)
    if f.prev_pos == {0, 0, 0} && f.bumper_pos != {0, 0, 0} { f.prev_pos = f.bumper_pos }
    combat_triggers(f, foe, ctx)
    locomotion_bumper(f, foe, ctx, cam)
    b: Pose_Blend
    pose_weights(f, ctx, &b)
    combat_strike(f, foe, ctx)
    pose_apply(f, ctx, &b)
    pose_model_matrix(f, ctx)
    f.prev_pos = f.bumper_pos
    f.tele_ok = false
}
