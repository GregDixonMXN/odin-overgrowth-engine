package spike22

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import gltf "vendor:cgltf"
// spike22 anim: clip sampling, shared-clip loading, retarget/IBM, foot IK.
sample_vec :: proc(anim: ^gltf.animation, node: ^gltf.node, path: gltf.animation_path_type, t: f32, out3: ^[3]f32, out4: ^[4]f32, loop: bool) -> bool {
    found := false
    for &ch in anim.channels {
        if ch.target_node != node || ch.target_path != path { continue }
        s := ch.sampler
        n := s.input.count
        if n == 0 { continue }
        times := make([]f32, n)
        defer delete(times)
        for i in 0 ..< n {
            v: [1]f32
            _ = gltf.accessor_read_float(s.input, i, &v[0], 1)
            times[i] = v[0]
        }
        dur := times[n - 1]
        tt := math.mod(t, dur if dur > 0 else 1.0) if loop else min(t, dur if dur > 0 else 1.0)
        j := uint(0)
        for j + 1 < n && times[j + 1] < tt { j += 1 }
        k := j + 1 if j + 1 < n else j
        span := times[k] - times[j]
        f := f32(0)
        if span > 0 { f = (tt - times[j]) / span }
        if path == .rotation {
            a, b: [4]f32
            _ = gltf.accessor_read_float(s.output, j, &a[0], 4)
            _ = gltf.accessor_read_float(s.output, k, &b[0], 4)
            dot := a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
            bb := b
            if dot < 0 { dot = -dot; bb = -b }
            dot = math.clamp(dot, -1.0, 1.0)
            theta := math.acos(dot)
            s0, s1: f32
            if theta < 1e-4 { s0, s1 = 1 - f, f } else {
                s0 = math.sin((1 - f) * theta) / math.sin(theta)
                s1 = math.sin(f * theta) / math.sin(theta)
            }
            out4^ = a * s0 + bb * s1
        } else {
            a, b: [3]f32
            _ = gltf.accessor_read_float(s.output, j, &a[0], 3)
            _ = gltf.accessor_read_float(s.output, k, &b[0], 3)
            out3^ = a * (1 - f) + b * f
        }
        found = true
    }
    return found
}

anim_dur_of :: proc(a: ^gltf.animation) -> f32 {
    mx := f32(0)
    for &ch in a.channels {
        s := ch.sampler
        n := s.input.count
        if n == 0 { continue }
        v: [1]f32
        _ = gltf.accessor_read_float(s.input, n - 1, &v[0], 1)
        if v[0] > mx { mx = v[0] }
    }
    return mx
}

// shared animation files (parsed once; sampling only reads them)
Shared_Anims :: struct {
    idata, rdata, jdata, sdata, ddata: ^gltf.data,
    idle, run, air, land, slash, kick, death: ^gltf.animation,
    air_dur, land_dur, slash_dur, kick_dur, death_dur: f32,
}

g_shki_bind_t: [][3]f32 // shki file bind translations (retarget reference)
g_shki_bind_n: int
g_shki_names: []string // normalized-name source list for cross-rig maps (never freed)

// IBM must invert OUR bind worlds (scaled translations), not the
// file's — for scale 1 this reproduces the file IBM exactly.
compute_fighter_ibm :: proc(f: ^Fighter) {
    data := f.data
    nn := f.nn
    nj := f.nj
    bw := make([][16]f32, nn)
    defer delete(bw)
    for i in 0 ..< nn {
        gltf.node_transform_world(&data.nodes[i], &bw[i][0])
    }
    for j in 0 ..< nj {
        f.ibm[j] = mat4_inverse(bw[f.joint_node[j]])
    }
}

// ---- shared animation files ----
load_shared_anims :: proc() -> Shared_Anims {
    sh: Shared_Anims
    {
        opts: gltf.options
        base := "../assets/"
        load := proc(opts: gltf.options, path: string) -> ^gltf.data {
            d, r := gltf.parse_file(opts, cstring(raw_data(path)))
            assert(r == .success, "parse failed")
            assert(gltf.load_buffers(opts, d, cstring(raw_data(path))) == .success, "buffers failed")
            return d
        }
        // NOTE: base mesh parsed per fighter in make_fighter; clips shared here.
        // Keep handles alive for the whole run (never freed).
        sh.idata = load(opts, "../assets/shki_idle.glb")
        sh.rdata = load(opts, "../assets/shki_run.glb")
        sh.jdata = load(opts, "../assets/shki_jump.glb")
        sh.sdata = load(opts, "../assets/shki_slash.glb")
        sh.ddata = load(opts, "../assets/shki_death.glb")
        _ = base
        assert(len(sh.idata.nodes) == 67 && len(sh.rdata.nodes) == 67 && len(sh.jdata.nodes) == 67 && len(sh.sdata.nodes) == 67 && len(sh.ddata.nodes) == 67, "rig mismatch")
        // source-name table for cross-rig node maps (raw names; matching
        // normalizes both sides, so 67- and 27-node rigs share one table)
        g_shki_names = make([]string, len(sh.idata.nodes))
        for i in 0 ..< len(sh.idata.nodes) { g_shki_names[i] = string(sh.idata.nodes[i].name) }
        sh.idle = &sh.idata.animations[0]
        sh.run  = &sh.rdata.animations[1] if len(sh.rdata.animations) >= 2 else &sh.rdata.animations[0]
        sh.air  = &sh.jdata.animations[0]
        sh.land = &sh.jdata.animations[2] if len(sh.jdata.animations) >= 3 else &sh.jdata.animations[1]
        sh.slash = &sh.sdata.animations[8]
        sh.kick = &sh.sdata.animations[4]
        sh.death = &sh.ddata.animations[0]
        sh.air_dur = anim_dur_of(sh.air)
        sh.land_dur = anim_dur_of(sh.land)
        sh.slash_dur = anim_dur_of(sh.slash)
        sh.kick_dur = anim_dur_of(sh.kick)
        sh.death_dur = anim_dur_of(sh.death)
        fmt.printf("shared clips: air=%.3f land=%.3f slash=%.3f kick=%.3f death=%.3f\n", sh.air_dur, sh.land_dur, sh.slash_dur, sh.kick_dur, sh.death_dur)
    }
    return sh
}

// ---- foot IK (Overgrowth CDrawLegImpl style) ----
// Runs post-pose, pre-palette, grounded Anim only. Per foot: heightfield
// ground sample -> smoothed plant -> lift/speed weight -> FABRIK 2-pass
// leg solve in model space -> from-to bone rotations. Reads f.world,
// rewrites leg nodes; caller recomputes worlds after.
fighter_leg_ik :: proc(f: ^Fighter, ctx: ^Ctx) {
    data := f.data
    if f.leg_idx[0] < 0 { return }
    mm := f.mm_last // 1-frame-lagged model matrix: fine, plants are smoothed
    // first frame mm_last is identity: init plants, skip solve
    first := mm[12] == 0 && mm[13] == 0 && mm[14] == 0
    for s in 0 ..< 2 {
        up_i := f.leg_idx[s * 3]
        kn_i := f.leg_idx[s * 3 + 1]
        ft_i := f.leg_idx[s * 3 + 2]
        a := f.leg_len[s * 2]
        b := f.leg_len[s * 2 + 1]
        if a < 1e-6 || b < 1e-6 { continue }
        // ankle model -> world (last frame's model matrix)
        am := [3]f32{f.world[ft_i][12], f.world[ft_i][13], f.world[ft_i][14]}
        aw := [3]f32{
            mm[0]*am.x + mm[4]*am.y + mm[8]*am.z + mm[12],
            mm[1]*am.x + mm[5]*am.y + mm[9]*am.z + mm[13],
            mm[2]*am.x + mm[6]*am.y + mm[10]*am.z + mm[14],
        }
        gy, ok := ground_at(ctx.hf, aw.x, aw.z, aw.y)
        if !ok { continue }
        // unreachable ground (cliff/hole beyond leg reach): ignore it,
        // or the leg snaps vertical trying (cut spawn sat on a cliff edge)
        if math.abs(gy - aw.y) > a + b + f.ankle_h + 0.5 { continue }
        if f.plant[s] < -1e8 || first {
            f.plant[s] = gy
            f.prev_ankle[s] = aw
            if first { continue }
        }
        // temporal smoothing: chase ground at most 3 m/s (no pops)
        dg := gy - f.plant[s]
        mx := 3.0 * ctx.dt
        if dg > mx { dg = mx } else if dg < -mx { dg = -mx }
        f.plant[s] += dg
        // weight: planted when the SOLE is low and the foot swings slow
        // relative to the body (world speed includes locomotion: subtract it)
        rel := (aw - f.prev_ankle[s]) / max(ctx.dt, 1e-4) - {f.bumper_vel.x, 0, f.bumper_vel.z}
        spd := linalg.length(rel)
        f.prev_ankle[s] = aw
        sole_target := f.plant[s] + f.ankle_h
        lift := aw.y - sole_target
        w := math.clamp(1.0 - lift / 0.3, 0.0, 1.0) * math.clamp(1.0 - spd / 3.0, 0.0, 1.0)
        if w < 0.01 { continue }
        // target: animated ankle, height pulled toward plant by weight
        H := [3]f32{f.world[up_i][12], f.world[up_i][13], f.world[up_i][14]}
        K := [3]f32{f.world[kn_i][12], f.world[kn_i][13], f.world[kn_i][14]}
        A := am
        dy := (sole_target - aw.y) * w // world units ~= model units (mm rigid)
        T := [3]f32{A.x, A.y + dy, A.z}
        // clamp reach
        d := T - H
        dl := linalg.length(d)
        maxd := a + b - 1e-4
        if dl > maxd && dl > 1e-9 { T = H + d * (maxd / dl) }
        mind := abs(a - b) + 1e-4
        if dl < mind {
            back := A - H
            if linalg.length(back) < 1e-6 { back = {0, -1, 0} }
            T = H + linalg.normalize(back) * mind
        }
        // FABRIK, 2 passes, knee keeps its bend side
        k, an := K, A
        for _ in 0 ..< 2 {
            an = T
            kk := k - an
            kl := linalg.length(kk)
            if kl > 1e-9 { k = an + kk * (b / kl) }
            kh := k - H
            hl := linalg.length(kh)
            if hl > 1e-9 { k = H + kh * (a / hl) }
            at := T - k
            al := linalg.length(at)
            if al > 1e-9 { an = k + at * (b / al) }
        }
        // write back: model-frame from-to rotations into parent space
        u0 := K - H
        u1 := k - H
        if linalg.length(u0) < 1e-9 || linalg.length(u1) < 1e-9 { continue }
        q := quat_from_vecs(linalg.normalize(u0), linalg.normalize(u1))
        pu := parent_of(data, up_i)
        if pu < 0 { continue }
        Qp := quat_from_world(f.world[pu])
        ql := quat_mul(quat_mul(quat_conj(Qp), q), Qp)
        nd_up := &data.nodes[up_i]
        nd_up.rotation = quat_mul(ql, nd_up.rotation)
        nd_up.has_rotation = true
        gltf.node_transform_world(&data.nodes[up_i], &f.world[up_i][0])
        v0 := A - K
        v1 := an - k
        if linalg.length(v0) < 1e-9 || linalg.length(v1) < 1e-9 { continue }
        r := quat_from_vecs(linalg.normalize(v0), linalg.normalize(v1))
        Qu := quat_from_world(f.world[up_i])
        rl2 := quat_mul(quat_mul(quat_conj(Qu), r), Qu)
        nd_kn := &data.nodes[kn_i]
        nd_kn.rotation = quat_mul(rl2, nd_kn.rotation)
        nd_kn.has_rotation = true
        // foot orientation: rotate sole toward terrain normal (from-to in
        // foot-parent space, same weight). Without this, planted ankles
        // still dangle toes-down.
        if gy2, ok2 := height_normal(ctx.hf, aw.x, aw.z); ok2 {
            // terrain normal (world) -> model frame via mm rotation
            nwx, nwy, nwz := gy2.x, gy2.y, gy2.z
            nm := [3]f32{
                mm[0]*nwx + mm[1]*nwy + mm[2]*nwz,
                mm[4]*nwx + mm[5]*nwy + mm[6]*nwz,
                mm[8]*nwx + mm[9]*nwy + mm[10]*nwz,
            }
            nl := linalg.length(nm)
            if nl > 1e-6 {
                nm /= nl
                Qf := quat_from_world(f.world[ft_i])
                sole := quat_rot_vec(Qf, {0, -1, 0})
                fa := quat_from_vecs(linalg.normalize(sole), nm)
                pf := parent_of(data, ft_i)
                if pf >= 0 {
                    Qpf := quat_from_world(f.world[pf])
                    fl := quat_mul(quat_mul(quat_conj(Qpf), fa), Qpf)
                    // slerp toward aligned by weight: q_identity -> fl
                    dot := fl[3]
                    if dot < 0 { dot = -dot }
                    dot = math.clamp(dot, -1.0, 1.0)
                    th := math.acos(dot)
                    s1 := w
                    if th > 1e-4 { s1 = math.sin(w * th) / math.sin(th) }
                    s0 := math.cos(w * th)
                    if fl[3] < 0 { s1 = -s1 }
                    fq := [4]f32{fl[0]*s1, fl[1]*s1, fl[2]*s1, s0 + fl[3]*s1}
                    nd_ft := &data.nodes[ft_i]
                    nd_ft.rotation = quat_mul(fq, nd_ft.rotation)
                    nd_ft.has_rotation = true
                }
            }
        }
    }
}
