package spike22

import "core:math"
import linalg "core:math/linalg"
import "core:c"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import gltf "vendor:cgltf"
import jph "../thirdparty/joltc-odin"
// spike22 pose: blend weights, palette, model matrix, kinematic glue, render.
Pose_Blend :: struct {
    clips: [5]^gltf.animation,
    ctimes: [5]f32,
    cloops: [5]bool,
    cw: [5]f32,
}

// ---- locomotion weights ----
pose_weights :: proc(f: ^Fighter, ctx: ^Ctx, b: ^Pose_Blend) {
    sh := ctx.sh
    dt := ctx.dt
    atk_clip := f.atk_anim if f.atk_anim != nil else sh.slash
    clips := [5]^gltf.animation{sh.idle, sh.run, sh.air, sh.land, atk_clip}
    ctimes := [5]f32{f.t_anim, f.t_run, f.air_t, f.land_elapsed, f.atk_t}
    cloops := [5]bool{true, true, false, false, false}
    f.state = "ragdoll"
    cw := [5]f32{}
    if f.do_anim {
        f.t_anim += dt
        if f.flash_t > 0 { f.flash_t -= dt }
        if f.atk_anim != nil && f.atk_t < f.atk_dur + 0.5 { f.atk_t += dt * f.atk_rate }
        // run-cycle rate follows ground speed (stride ~1.4m vs 0.208s asset cycle)
        f.t_run += dt * f.run_rate
        f.run_rate = math.clamp(f.speed * 0.208 / 1.4, 0.3, 1.2) if f.speed > 0.1 else 0.3
        if f.land_t > 0 && f.grounded { f.land_elapsed += dt }
        f.state = "run"
        if !f.grounded {
            cw[2] = 1; f.state = "air"
        } else if f.land_t > 0 {
            cw[3] = 1; f.state = "land"; f.land_t -= dt
        } else if f.sneaking {
            // sneak: run cycle sunk into the land crouch (crouch-walk)
            f.land_elapsed = sh.land_dur * 0.4
            cw = {0, 0.5, 0, 0.5, 0}
            f.state = "sneak"
        } else {
            w_run := math.clamp((f.speed - 0.5) / 2.0, 0.0, 1.0)
            cw[0] = 1 - w_run; cw[1] = w_run
            f.state = "idle" if f.speed < 0.8 else "run"
        }
        if f.atk_anim != nil && f.atk_t < f.atk_dur {
            // attack blends over the locomotion underneath (0.12s in,
            // 0.10s out) instead of hard-cutting: chains don't pop.
            ab := math.min(f.atk_t / 0.12, (f.atk_dur - f.atk_t) / 0.10)
            ab = math.clamp(ab, 0.0, 1.0)
            cw[0] *= 1 - ab; cw[1] *= 1 - ab; cw[2] *= 1 - ab; cw[3] *= 1 - ab
            cw[4] = ab
            if f.dying {
                f.state = "dying"
            } else {
                f.state = "kick" if f.atk_kick else "attack"
            }
        } else if f.blocking {
            // guard pose: land clip pinned at 60% (crouch). Rising edge
            // pins the time so it holds instead of playing through.
            f.land_elapsed = sh.land_dur * 0.6
            cw = {0, 0, 0, 1, 0}
            f.state = "block"
        }
    }
    b.clips = clips
    b.ctimes = ctimes
    b.cloops = cloops
    b.cw = cw
}

// ---- pose ----
pose_apply :: proc(f: ^Fighter, ctx: ^Ctx, b: ^Pose_Blend) {
    sh := ctx.sh
    bi := ctx.bi
    dt := ctx.dt
    data := f.data
    nn := f.nn
    clips := b.clips
    ctimes := b.ctimes
    cloops := b.cloops
    cw := b.cw
    if f.do_anim {
        for i in 0 ..< nn {
            data.nodes[i].translation = f.base_t[i]
            data.nodes[i].rotation = f.base_r[i]
            data.nodes[i].scale = f.base_s[i]
            data.nodes[i].has_translation = f.base_ht[i]
            data.nodes[i].has_rotation = f.base_hr[i]
            data.nodes[i].has_scale = f.base_hs[i]
            f.has_c[i] = false
            f.wsum[i] = 0
        }
        for c in 0 ..< 5 {
            if cw[c] <= 0 { continue }
            for i in 0 ..< nn {
                // cross-rig sampling: fighter node i is driven by its
                // name-mapped shki clip node. -1 = no counterpart (extra
                // toes, head tips): holds bind. Identity on shki rigs.
                src := f.src_map[i]
                if src < 0 { continue }
                nd: ^gltf.node
                switch c {
                case 0:
                    if src >= len(sh.idata.nodes) { continue }
                    nd = &sh.idata.nodes[src]
                case 1:
                    if src >= len(sh.rdata.nodes) { continue }
                    nd = &sh.rdata.nodes[src]
                case 2, 3:
                    if src >= len(sh.jdata.nodes) { continue }
                    nd = &sh.jdata.nodes[src]
                case 4:
                    // attack slot: slash/kick live in sdata, death in ddata
                    if clips[4] == sh.death {
                        if src >= len(sh.ddata.nodes) { continue }
                        nd = &sh.ddata.nodes[src]
                    } else {
                        if src >= len(sh.sdata.nodes) { continue }
                        nd = &sh.sdata.nodes[src]
                    }
                case: nd = &data.nodes[i]
                }
                v3: [3]f32
                v4: [4]f32
                if sample_vec(clips[c], nd, .translation, ctimes[c], &v3, &v4, cloops[c]) {
                    if !f.has_c[i] { f.samp_t[i] = v3 } else {
                        k := cw[c] / (f.wsum[i] + cw[c])
                        f.samp_t[i] = f.samp_t[i] * (1 - k) + v3 * k
                    }
                }
                if sample_vec(clips[c], nd, .rotation, ctimes[c], &v3, &v4, cloops[c]) {
                    if !f.has_c[i] { f.samp_r[i] = v4 } else {
                        k := cw[c] / (f.wsum[i] + cw[c])
                        f.samp_r[i] = slerp44(f.samp_r[i], v4, k)
                    }
                }
                if sample_vec(clips[c], nd, .scale, ctimes[c], &v3, &v4, cloops[c]) {
                    if !f.has_c[i] { f.samp_s[i] = v3 } else {
                        k := cw[c] / (f.wsum[i] + cw[c])
                        f.samp_s[i] = f.samp_s[i] * (1 - k) + v3 * k
                    }
                }
                v3b: [3]f32
                v4b: [4]f32
                if sample_vec(clips[c], nd, .translation, ctimes[c], &v3b, &v4b, cloops[c]) ||
                   sample_vec(clips[c], nd, .rotation, ctimes[c], &v3b, &v4b, cloops[c]) {
                    if f.has_c[i] { f.wsum[i] += cw[c] } else { f.has_c[i] = true; f.wsum[i] = cw[c] }
                }
            }
        }
        for i in 0 ..< nn {
            if !f.has_c[i] { continue }
            nd := &data.nodes[i]
            if f.is_root[i] {
                nd.has_translation = false
                nd.translation = {0, 0, 0}
            } else if f.same_rig && f.model_scale == 1.0 {
                // same-rig: translations carry over; retargeted rigs keep
                // their own bind translations — clip translations encode
                // shki bone lengths, not the target's
                nd.translation = f.samp_t[i] * f.model_scale; nd.has_translation = true
            } else if src := f.src_map[i]; src >= 0 && src < g_shki_bind_n {
                // cross-rig: bind-relative delta transfer. Clip rotations
                // need matching centers: pose = our bind + the clip's
                // deviation from SHKI bind. The deviation ships in
                // shki-clip units (cm convention), so it is scaled by
                // retarget_k into this rig's local units (0.01 for
                // meter rigs). lunk-scale rigs keep the legacy 1.2.
                // (Pure rotation-copy rips parts off on lever arms; a
                // per-joint magnitude ratio is fooled by stance offsets.)
                sb := g_shki_bind_t[src]
                d := f.samp_t[i] - sb
                k := f32(1.2) if f.same_rig else f.retarget_k
                nd.translation = f.base_t[i] + d * k; nd.has_translation = true
            }
            nd.rotation = f.samp_r[i]; nd.has_rotation = true
            nd.scale = f.samp_s[i]; nd.has_scale = true
        }
        if f.rec_blend < 1 {
            f.rec_blend = min(f.rec_blend + dt / 0.35, 1)
            k := f.rec_blend * f.rec_blend * (3 - 2 * f.rec_blend)
            for i in 0 ..< nn {
                if f.is_root[i] { continue }
                nd := &data.nodes[i]
                nd.translation = f.rec_t[i] * (1 - k) + nd.translation * k
                nd.rotation = slerp44(f.rec_r[i], nd.rotation, k)
                nd.has_translation = true
                nd.has_rotation = true
            }
        }
    }
    if f.mode == .Ragdoll {
        // drag the frozen frame along with the pelvis: model-space stays
        // glued to the body (rotation stays handoff-frozen, no spinning)
        pp: jph.RVec3
        jph.BodyInterface_GetPosition(bi, f.rb_ids[0], &pp)
        f.mm_freeze[12] = pp.x
        f.mm_freeze[13] = pp.y
        f.mm_freeze[14] = pp.z
    ragdoll_hold_shape(f, bi, dt, pp)
        tmp: [16]f32
        for b in 0 ..< RB_N {
            wtb: jph.RMat4
            jph.BodyInterface_GetWorldTransform(bi, f.rb_ids[b], &wtb)
            wbw := transmute([16]f32)wtb
            pin_node_world(data, f.rb_node[b], mul_col(inverse_rigid(f.mm_freeze), mul_col(wbw, f.rb_off[b])), &tmp)
        }
    }
    for i in 0 ..< nn {
        gltf.node_transform_world(&data.nodes[i], &f.world[i][0])
    }
    if f.do_anim && f.mode == .Anim && f.grounded {
        // foot IK post-pass (rewrites leg nodes); recompute worlds after
        fighter_leg_ik(f, ctx)
        for i in 0 ..< nn {
            gltf.node_transform_world(&data.nodes[i], &f.world[i][0])
        }
    }
    for j in 0 ..< f.nj {
        f.palette[j] = mul_col(f.world[f.joint_node[j]], f.ibm[j])
    }
}

// ---- model matrix (yaw + slope-aligned up) + kinematic glue ----
pose_model_matrix :: proc(f: ^Fighter, ctx: ^Ctx) {
    bi := ctx.bi
    dt := ctx.dt
    U := f.slope_up
    fw0 := [3]f32{math.sin(f.yaw), 0, math.cos(f.yaw)}
    rt := linalg.normalize(linalg.cross(U, fw0))
    fw := linalg.cross(rt, U)
    mm: [16]f32 = {
        rt.x, rt.y, rt.z, 0,
        U.x, U.y, U.z, 0,
        fw.x, fw.y, fw.z, 0,
        f.bumper_pos.x, f.bumper_pos.y, f.bumper_pos.z, 1,
    }
    f.render_mm = mm
    if f.mode == .Anim && f.do_anim {
        if f.roll_t > 0 {
            // landing roll reads as a forward flip: one full tumble over
            // the 0.55s slide. The flip pivots around the body center, not
            // the feet (feet-pivot buries the head underground mid-roll):
            // lift = H*(1-cos)/2 keeps head/feet above the dirt, H ~ shki
            // head height in meters.
            th := (1.0 - f.roll_t / 0.55) * 2.0 * math.PI
            c, s := math.cos(th), math.sin(th)
            U2 := U * c + fw * s
            fw2 := fw * c - U * s
            lift := f32(1.6) * (1.0 - c) * 0.5
            f.render_mm = {
                rt.x, rt.y, rt.z, 0,
                U2.x, U2.y, U2.z, 0,
                fw2.x, fw2.y, fw2.z, 0,
                f.bumper_pos.x, f.bumper_pos.y + lift, f.bumper_pos.z, 1,
            }
        } else if f.dodge_t > 0 {
            // dash leans into the run: fixed nose-down tilt while i-frames burn
            c, s := math.cos(f32(0.35)), math.sin(f32(0.35))
            U2 := U * c + fw * s
            fw2 := fw * c - U * s
            f.render_mm = {
                rt.x, rt.y, rt.z, 0,
                U2.x, U2.y, U2.z, 0,
                fw2.x, fw2.y, fw2.z, 0,
                f.bumper_pos.x, f.bumper_pos.y, f.bumper_pos.z, 1,
            }
        }
    }
    if f.mode == .Ragdoll { f.render_mm = f.mm_freeze }
    f.mm_last = mm
    if f.do_anim {
        qk: jph.Quat = 1
        for b in 0 ..< RB_N {
            lb := [3]f32{f.world[f.rb_node[b]][12], f.world[f.rb_node[b]][13], f.world[f.rb_node[b]][14]}
            wp := yaw_rot(lb, f.yaw) + f.bumper_pos
            wpp := jph.RVec3{wp.x, wp.y, wp.z}
            jph.BodyInterface_MoveKinematic(bi, f.rb_ids[b], &wpp, &qk, dt)
        }
    }
}

render_fighter :: proc(f: ^Fighter) {
    // hit flash: material tint lerps to white while flash_t burns
    // (the sword keeps its own steel — never takes the fighter tint)
    if f.flash_t > 0 {
        k := math.clamp(f.flash_t / 0.12, 0.0, 1.0)
        fc := rl.Color{
            u8(f32(f.tint.r) + (255 - f32(f.tint.r)) * k),
            u8(f32(f.tint.g) + (255 - f32(f.tint.g)) * k),
            u8(f32(f.tint.b) + (255 - f32(f.tint.b)) * k),
            255,
        }
        for &pr, i in f.prims {
            pr.mat.maps[0].color = rl.WHITE if i == f.sword_idx else fc
        }
    } else {
        for &pr, i in f.prims {
            pr.mat.maps[0].color = rl.WHITE if i == f.sword_idx else f.tint
        }
    }
    if f.has_sword && f.sword_idx >= 0 && f.sword_idx < len(f.prims) {
        // re-seat the sword on the hand every frame (anim + ragdoll both
        // recompute f.world). Grip maps blade -z onto hand -y (fist line).
        // NOTE: stale-cm rigs (shki) carry 0.01 Armature scale, so every
        // world matrix is 100x shrunk in rotation (skin survives via IBM
        // cancelling it; translations are true meters). Unscale for the
        // rigid prop; true-scale rigs (assetdrop) ride at 1:1.
        // f.world_unscale is measured per rig at build, not assumed.
        SWORD_GRIP := [16]f32{1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1}
        uni := f.world_unscale
        SWORD_UNSCALE := [16]f32{uni, 0, 0, 0, 0, uni, 0, 0, 0, 0, uni, 0, 0, 0, 0, 1}
        f.prims[f.sword_idx].rigid_m = mul_col(mul_col(f.world[f.hand_node], SWORD_UNSCALE), SWORD_GRIP)
    }
    for &pr, i in f.prims {
        if pr.skinned {
            for i in 0 ..< pr.count {
                px := pr.pos[i*3]; py := pr.pos[i*3+1]; pz := pr.pos[i*3+2]
                nx := pr.nrm[i*3]; ny := pr.nrm[i*3+1]; nz := pr.nrm[i*3+2]
                ox, oy, oz := f32(0), f32(0), f32(0)
                orx, ory, orz := f32(0), f32(0), f32(0)
                for k in 0 ..< 4 {
                    w := pr.weights[i][k]
                    if w <= 0 { continue }
                    m := &f.palette[pr.joints[i][k]]
                    ox += w * (m[0]*px + m[4]*py + m[8]*pz + m[12])
                    oy += w * (m[1]*px + m[5]*py + m[9]*pz + m[13])
                    oz += w * (m[2]*px + m[6]*py + m[10]*pz + m[14])
                    orx += w * (m[0]*nx + m[4]*ny + m[8]*nz)
                    ory += w * (m[1]*nx + m[5]*ny + m[9]*nz)
                    orz += w * (m[2]*nx + m[6]*ny + m[10]*nz)
                }
                il := 1.0 / math.max(math.sqrt(orx*orx + ory*ory + orz*orz), 1e-6)
                pr.dst[i*3] = ox; pr.dst[i*3+1] = oy; pr.dst[i*3+2] = oz
                // NaN guard: a bad palette row flings a vert to infinity
                // (the long-triangle streaks). Healthy verts sum < 4
                // (measured 3.35 across the whole card); anything past 12
                // is a fling. Fall back to rest pose.
                if ox != ox || oy != oy || oz != oz || math.abs(ox) + math.abs(oy) + math.abs(oz) > 12 {
                    pr.dst[i*3] = px; pr.dst[i*3+1] = py; pr.dst[i*3+2] = pz
                }
                pr.dstn[i*3] = orx * il; pr.dstn[i*3+1] = ory * il; pr.dstn[i*3+2] = orz * il
            }
            if pr.sev_node >= 0 && pr.sev_node < len(f.world) {
                // sever stump: park cut verts on the joint (rides anim +
                // ragdoll — the skeleton keeps moving underneath)
                jx := f.world[pr.sev_node][12]
                jy := f.world[pr.sev_node][13]
                jz := f.world[pr.sev_node][14]
                for i in pr.sev_idx {
                    pr.dst[i*3] = jx; pr.dst[i*3+1] = jy; pr.dst[i*3+2] = jz
                }
            }
            rl.UpdateMeshBuffer(pr.mesh, 0, pr.mesh.vertices, c.int(pr.count * 3 * size_of(f32)), 0)
            rl.UpdateMeshBuffer(pr.mesh, 2, pr.mesh.normals, c.int(pr.count * 3 * size_of(f32)), 0)
            if pr.dbl_side { rlgl.DisableBackfaceCulling() }
            rl.DrawMesh(pr.mesh, pr.mat, to_rl(f.render_mm))
            if pr.dbl_side { rlgl.EnableBackfaceCulling() }
        } else {
            if i == f.sword_idx && !f.has_sword { continue } // disarmed: stays on the ground
            rl.DrawMesh(pr.mesh, pr.mat, to_rl(mul_col(f.render_mm, pr.rigid_m)))
        }
    }
}
