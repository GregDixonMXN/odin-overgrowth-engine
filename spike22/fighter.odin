package spike22

import linalg "core:math/linalg"
import "core:c"
import "core:fmt"
import rl "vendor:raylib"
import gltf "vendor:cgltf"
import jph "../thirdparty/joltc-odin"
// spike22 fighters: Mode/Skinned_Prim/Fighter/Ctx types, fighter construction.
Mode :: enum { Anim, Ragdoll }

Skinned_Prim :: struct {
    mesh:     rl.Mesh,
    mat:      rl.Material,
    count:    int,
    pos:      []f32,
    nrm:      []f32,
    dst:      []f32,
    dstn:     []f32,
    joints:   [][4]u16,
    weights:  [][4]f32,
    node_idx: int,
    rigid_m:  [16]f32,
    skinned:  bool,
    dbl_side: bool, // from glTF material.doubleSided
    idx:      []u16, // chunk indices (kept CPU-side for sever surgery)
    uv:       []f32, // chunk uvs (kept CPU-side so pieces stay textured)
    sev_node: int, // severed joint subtree root (node idx, -1 = whole)
    sev_idx:  []int, // collapsed verts (parked on sev_node in render)
}

Fighter :: struct {
    data: ^gltf.data,
    nn: int,
    base_t: [][3]f32, base_r: [][4]f32, base_s: [][3]f32,
    base_ht, base_hr, base_hs: []b32,
    is_root: []bool,
    joint_node: []int, ibm: [][16]f32, nj: int,
    prims: [dynamic]Skinned_Prim,
    world: [][16]f32, palette: [][16]f32,
    samp_t: [][3]f32, samp_r: [][4]f32, samp_s: [][3]f32,
    has_c: []bool, wsum: []f32,
    rec_t: [][3]f32, rec_r: [][4]f32, rec_blend: f32,
    bumper_pos, bumper_vel: [3]f32,
    vy: f32, grounded: bool, land_t: f32, yaw: f32, speed: f32,
    t_anim, air_t, land_elapsed, atk_t: f32,
    t_run, run_rate: f32, // run-clip clock + speed-matched playback rate
    struck: bool,      // strike moment passed (once per attack)
    connected: bool,   // strike made contact (damage or juggle): cancels open
    atk_rate: f32,     // attack playback rate (player swings faster)
    atk_anim: ^gltf.animation, atk_dur: f32, atk_kick: bool,
    mode: Mode, do_anim: bool, state: string,
    rb_node: [RB_N]int, rb_bind: [RB_N][3]f32,
    rb_ids: [RB_N]jph.BodyID, rb_off: [RB_N][16]f32,
    glue_w: [RB_N][3]f32, // handoff world pos per body (active-ragdoll shape)
    mm_freeze, mm_last, render_mm: [16]f32,
    is_player: bool,
    team: int,        // 0 = your side, 1 = theirs (foe = nearest enemy)
    name: string,     // log labels: "player" "ally" "dummy" "cut"
    handoff_age: f32,
    hp: int,          // 0 = K.O.
    respawn_t: f32,   // counts while K.O.
    slope_up: [3]f32, // smoothed slope-aligned up (model leans into hills)
    model_scale: f32, // uniform scale vs the authored rig (lunk = 0.12)
    accel_rate, top_speed: f32,
    normal_tex: rl.Texture2D,
    has_normal: bool,
    max_hp: int,      // full-HP value for (re)spawn
    dmg: int,         // HP damage per landed hit
    kicks: bool,      // AI only ever kicks (brute character)
    blocking: bool,   // guard held (Shift / AI reaction): negates strikes
    block_t: f32,     // AI block latch timer (stable, no strobing)
    // v1 brain: CHASE 0 / CIRCLE 1 / RETREAT 2 / STRIKE 3 (+ personality)
    ai_state: int,
    ai_t: f32,        // state timer (orbit duration, retreat length)
    ai_dir: f32,      // orbit direction (+1 / -1, rolled on entry)
    ai_cool: f32,     // swing cooldown (aggression sets its length)
    ai_aggr: f32,     // 0 cautious .. 1 relentless (swing rate, retreat odds)
    ai_range: f32,    // preferred striking distance
    ai_want: int,     // swing the brain ordered this frame (0/1/2)
    info_pos: [3]f32, // last-known foe position (sight + hearing)
    info_frame: int,  // frame it was planted (stale past 240)
    dying: bool,      // death performance playing (then ragdoll)
    death_hv: [3]f32, // mild carry velocity applied at death handoff
    stagger_t: f32,   // light-hit flinch timer: stays up, no atk/guard, damped
    vault_cd: f32,    // vault/walljump cooldown (no multi-trigger spam)
    step_acc: f32,    // distance since last footstep sound
    step_idx: u32,    // footstep variant cycle
    dodge_t:  f32,    // dash active (i-frames while > 0)
    dodge_cd: f32,    // dash cooldown
    dodge_dir: [3]f32,// dash world direction
    tap_key:  int,    // last tapped move key (1W 2S 3D 4A, double-tap = dodge)
    tap_t:    f32,    // double-tap window remaining
    block_age: f32,   // time guard has been held (fresh guard = counter window)
    roll_t:   f32,    // landing-roll tumble (steering locked, no atk/guard)
    sneaking: bool,   // C-held crouch-walk: slow, silent, dulls AI, sharpens counters
    sneak_atk: bool,  // latched at swing start: the strike came from stealth
    grab_victim: ^Fighter, // holding this foe: drag slow, J/K/F throws them
    grabbed_by: ^Fighter,  // held: dragged along, struggle 1.2s breaks free
    hold_t: f32,           // struggle timer remaining on the victim
    prev_pos: [3]f32,    // bumper at last update end (teleport guard baseline)
    tele_ok: bool,         // set by respawn/recover: big moves are legitimate
    carry_idx: int,        // crate carried overhead (-1 = none; throw with any attack)
    prev_hp: int,          // hp last update (a drop stamps hurt_f)
    hurt_f: int,           // frame of last HP loss (regen needs 6s calm)
    regen_acc: f32,        // calm seconds banked toward +1 HP
    hanging: bool,    // ledge hang: gravity off, shimmy/pop/drop only
    hang_box: int,    // box index caught
    hang_face: int,   // 0:-x 1:+x 2:-z 3:+z
    hang_t: f32,      // time on the lip (AI mounts after 0.5s)
    tint: rl.Color,   // base material tint (hit flash lerps to white)
    flash_t: f32,     // hit-flash timer (seconds)
    has_sword: bool,  // rigid sword prop riding the right hand (node 47)
    sword_idx: int,   // prim index of the sword (-1 = none)
    hand_node: int,   // RightHand node (resolved by name; 47 on shki, 12 on assetdrop)
    world_unscale: f32, // 100 on stale-cm rigs (shki), 1 on true-scale rigs
    same_rig: bool,   // node-for-node shki layout (identity clip map)
    src_map: []int,   // fighter node -> shki clip node (-1 = hold bind)
    retarget_k: f32,  // clip->local translation unit scale (cm deltas to local units)
    // foot-IK state: leg chains (up/knee/foot node per side), bind bone
    // lengths, smoothed plant heights (world), prev ankle pos (world)
    leg_idx: [6]int,   // L up/knee/foot, R up/knee/foot
    leg_len: [4]f32,   // L upper/lower, R upper/lower (bind, model meters)
    ankle_h: f32,      // ankle joint height above sole (bind, model meters)
    plant: [2]f32,     // smoothed ground height under each foot (world)
    prev_ankle: [2][3]f32,
}

Ctx :: struct {
    sh: ^Shared_Anims,
    bi: ^jph.BodyInterface,
    crate_ids: [6]jph.BodyID,
    hf: ^Heightfield,
    dt: f32, frame: int, auto: bool,
    brains: bool, // enemies think (manual play + autoai harness; auto holds still)
    hitstop_f: int,  // freeze updates+physics this many frames (impact)
    shake: f32,      // screenshake magnitude (decays)
    hide_player: bool, // lens inside our own head: skip our mesh this frame
    ally_anchor: [3]f32, // escort post: ally regroups here when far
}

make_fighter :: proc(base_path: string, tint: rl.Color, model_scale: f32, albedo_path: string, normal_path := "") -> Fighter {
    f: Fighter
    f.tint = tint
    f.sword_idx = -1
    f.carry_idx = -1 // no crate overhead
    f.model_scale = model_scale
    f.accel_rate = 12.0
    f.top_speed = 6.5
    f.max_hp = 3
    f.dmg = 1
    opts: gltf.options
    data, res := gltf.parse_file(opts, cstring(raw_data(base_path)))
    assert(res == .success, "parse base failed")
    assert(gltf.load_buffers(opts, data, cstring(raw_data(base_path))) == .success, "buffers base failed")
    f.data = data
    nn := len(data.nodes)
    f.nn = nn
    f.base_t = make([][3]f32, nn)
    f.base_r = make([][4]f32, nn)
    f.base_s = make([][3]f32, nn)
    f.base_ht = make([]b32, nn)
    f.base_hr = make([]b32, nn)
    f.base_hs = make([]b32, nn)
    for i in 0 ..< nn {
        nd := &data.nodes[i]
        // scale translations into model space now (rotations carry over raw);
        // live nodes scaled too so bind-pose measurement matches
        nd.translation *= model_scale
        f.base_t[i] = nd.translation; f.base_r[i] = nd.rotation; f.base_s[i] = nd.scale
        f.base_ht[i] = nd.has_translation; f.base_hr[i] = nd.has_rotation; f.base_hs[i] = nd.has_scale
    }
    f.is_root = make([]bool, nn)
    for i in 0 ..< nn { f.is_root[i] = data.nodes[i].parent == nil }
    // cross-rig clip map: fighter node -> shki clip node by normalized
    // joint name (-1 = no counterpart: holds bind). 67-node shki/lunk
    // rigs map identity; the 27-node assetdrop rig maps its major
    // joints and holds the extras (toes, head tips) at bind.
    assert(len(g_shki_names) > 0, "shared anims must load before fighters")
    f.src_map = make([]int, nn)
    for i in 0 ..< nn {
        f.src_map[i] = -1
        for j in 0 ..< len(g_shki_names) {
            if joint_matches(string(data.nodes[i].name), g_shki_names[j]) { f.src_map[i] = j; break }
        }
    }
    // same rig = clip layout: every mapped node sits at its own index.
    // Unmapped nodes (lunk's renamed mesh holder) hold bind, exactly as
    // before when they carried no channels. Count alone is not enough.
    f.same_rig = (nn == len(g_shki_names))
    if f.same_rig {
        for i in 0 ..< nn {
            if f.src_map[i] >= 0 && f.src_map[i] != i { f.same_rig = false; break }
        }
    }
    f.hand_node = find_joint(data, "mixamorig:RightHand")
    // world-matrix scale probe: stale-cm rigs (shki 0.01 Armature) shrink
    // the rotation block 100x and rigid props must unscale; true-scale
    // rigs (assetdrop, baked to meters) ride at 1:1. Measured against
    // model_scale (which also shrinks bind worlds, e.g. lunk 0.12).
    f.world_unscale = 1
    f.retarget_k = 1
    if hi := find_joint(data, "mixamorig:Hips"); hi >= 0 {
        hw: [16]f32
        gltf.node_transform_world(&data.nodes[hi], &hw[0])
        cn := linalg.length([3]f32{hw[0], hw[1], hw[2]})
        if cn > 1e-9 { f.world_unscale = f.model_scale / cn }
        // clip translation deltas ship in shki-clip units (cm convention:
        // stale 0.01 Armature scale). Convert to this rig's local units:
        // meters = d_cm * 0.01, local = meters / net_scale, where
        // net_scale (rotation-block column norm x model_scale) is what
        // scales this rig's translations into the world.
        if cn * f.model_scale > 1e-9 { f.retarget_k = 0.01 / (cn * f.model_scale) }
        fmt.printf("%s rig: nn=%d same_rig=%v hand=%d unscale=%.2f retarget_k=%.3f hips_y=%.2f\n",
            base_path, nn, f.same_rig, f.hand_node, f.world_unscale, f.retarget_k, hw[13])
    }

    // albedo texture (per-fighter file, per-fighter GPU copy)
    tex: rl.Texture2D
    has_tex := false
    {
        // empty albedo_path = untextured (file baseColor): keep material color
        rim: rl.Image
        if albedo_path != "" {
            rim = rl.LoadImage(cstring(raw_data(albedo_path)))
            if rim.data != nil {
                tex = rl.LoadTextureFromImage(rim)
                rl.UnloadImage(rim)
                if tex.id != 0 { has_tex = true }
            }
        }
        if normal_path != "" {
            ntex: rl.Texture2D
            has_ntex := false
            {
                nim := rl.LoadImage(cstring(raw_data(normal_path)))
                if nim.data != nil {
                    ntex = rl.LoadTextureFromImage(nim)
                    rl.UnloadImage(nim)
                    if ntex.id != 0 { has_ntex = true }
                }
            }
            if has_ntex {
                // store on the shared tex slot list via material at emit time
                f.normal_tex = ntex
                f.has_normal = true
            }
        }
    }

    // skin info
    skin := &data.skins[0]
    nj := len(skin.joints)
    f.nj = nj
    f.joint_node = make([]int, nj)
    for j in 0 ..< nj {
        for i in 0 ..< nn {
            if skin.joints[j] == &data.nodes[i] { f.joint_node[j] = i; break }
        }
    }
    f.ibm = make([][16]f32, nj)
    compute_fighter_ibm(&f)
    // IBM inverts our (possibly scaled) bind — exact by construction.

    // render prims (split >60k-vert prims for raylib's u16 indices)
    f.prims = make([dynamic]Skinned_Prim)
    for mi in 0 ..< len(data.meshes) {
        m := &data.meshes[mi]
        owner := -1
        for i in 0 ..< nn {
            if data.nodes[i].mesh == m { owner = i; break }
        }
        for pi in 0 ..< len(m.primitives) {
            p := &m.primitives[pi]
            n := 0
            pname := make([]string, len(p.attributes))
            defer delete(pname)
            pdata := make([]^gltf.accessor, len(p.attributes))
            defer delete(pdata)
            for ai in 0 ..< len(p.attributes) {
                pname[ai] = string(p.attributes[ai].name)
                pdata[ai] = p.attributes[ai].data
            }
            get := proc(names: []string, datas: []^gltf.accessor, want: string) -> ^gltf.accessor {
                for i in 0 ..< len(names) {
                    if names[i] == want { return datas[i] }
                }
                return nil
            }
            apos := get(pname, pdata, "POSITION")
            anrm := get(pname, pdata, "NORMAL")
            auv  := get(pname, pdata, "TEXCOORD_0")
            ajt  := get(pname, pdata, "JOINTS_0")
            awt  := get(pname, pdata, "WEIGHTS_0")
            assert(apos != nil && anrm != nil && auv != nil, "missing core attribs")
            n = int(apos.count)
            verts := make([]f32, n * 3)
            nrms  := make([]f32, n * 3)
            uvs   := make([]f32, n * 2)
            for i in 0 ..< n {
                _ = gltf.accessor_read_float(apos, uint(i), &verts[i * 3], 3)
                _ = gltf.accessor_read_float(anrm, uint(i), &nrms[i * 3], 3)
                _ = gltf.accessor_read_float(auv,  uint(i), &uvs[i * 2], 2)
            }
            if model_scale != 1.0 {
                for i in 0 ..< n * 3 { verts[i] *= model_scale }
            }
            nidx := int(p.indices.count)
            raw_idx := make([]uint, nidx)
            for i in 0 ..< nidx {
                raw_idx[i] = uint(gltf.accessor_read_index(p.indices, uint(i)))
            }
            skinned := ajt != nil && awt != nil
            all_joints: [][4]u16
            all_weights: [][4]f32
            if skinned {
                all_joints = make([][4]u16, n)
                all_weights = make([][4]f32, n)
                for i in 0 ..< n {
                    ju: [4]c.uint
                    _ = gltf.accessor_read_uint(ajt, uint(i), &ju[0], 4)
                    _ = gltf.accessor_read_float(awt, uint(i), &all_weights[i][0], 4)
                    // loader hardening: some exports park 255 in unused
                    // joint slots, ship negative weights, or skip
                    // normalization. Any of those reads outside the
                    // palette or inverts verts, so clamp joint range,
                    // drop non-positive weights, renormalize. No-op on
                    // clean rigs (shki/lunk measure 0/0/0 on all three).
                    s := f32(0)
                    for k in 0 ..< 4 {
                        if int(ju[k]) >= nj || all_weights[i][k] <= 0 {
                            all_joints[i][k] = 0
                            all_weights[i][k] = 0
                        } else {
                            all_joints[i][k] = u16(ju[k])
                            s += all_weights[i][k]
                        }
                    }
                    if s > 1e-6 {
                        for k in 0 ..< 4 { all_weights[i][k] /= s }
                    } else {
                        // orphan vert: pin to joint 0 (rest pose, never flings)
                        all_joints[i] = [4]u16{0, 0, 0, 0}
                        all_weights[i] = [4]f32{1, 0, 0, 0}
                    }
                }
            }
            mat := rl.LoadMaterialDefault()
            if has_tex { rl.SetMaterialTexture(&mat, .ALBEDO, tex) }
            if f.has_normal { rl.SetMaterialTexture(&mat, .NORMAL, f.normal_tex) }
            mat.maps[0].color = tint
            dbl := p.material != nil && bool(p.material.double_sided)
            rm: [16]f32 = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
            if !skinned && owner >= 0 {
                gltf.node_transform_world(&data.nodes[owner], &rm[0])
            }
            emit_chunk :: proc(prims: ^[dynamic]Skinned_Prim, verts, nrms: []f32, uvs: []f32,
                all_joints: [][4]u16, all_weights: [][4]f32, chunk_verts: []int, chunk_idx: []uint,
                mat: rl.Material, owner: int, rm: [16]f32, skinned: bool, dbl_side: bool) {
                cn := len(chunk_verts)
                cverts := make([]f32, cn * 3)
                cnrms  := make([]f32, cn * 3)
                cuvs   := make([]f32, cn * 2)
                cj: [][4]u16
                cw: [][4]f32
                if skinned {
                    cj = make([][4]u16, cn)
                    cw = make([][4]f32, cn)
                }
                for oi, ni in chunk_verts {
                    assert(ni*3+2 < len(cverts), "cverts ni oob")
                    assert(oi*3+2 < len(verts), "verts oi oob")
                    cverts[ni*3] = verts[oi*3]; cverts[ni*3+1] = verts[oi*3+1]; cverts[ni*3+2] = verts[oi*3+2]
                    cnrms[ni*3] = nrms[oi*3]; cnrms[ni*3+1] = nrms[oi*3+1]; cnrms[ni*3+2] = nrms[oi*3+2]
                    cuvs[ni*2] = uvs[oi*2]; cuvs[ni*2+1] = uvs[oi*2+1]
                    if skinned { cj[ni] = all_joints[oi]; cw[ni] = all_weights[oi] }
                }
                cidx := make([]u16, len(chunk_idx))
                for v, i in chunk_idx { cidx[i] = u16(v) }
                dst := make([]f32, cn * 3)
                dstn := make([]f32, cn * 3)
                copy(dst, cverts)
                copy(dstn, cnrms)
                mesh := rl.Mesh{
                    vertexCount = c.int(cn), triangleCount = c.int(len(cidx) / 3),
                    vertices = raw_data(dst), texcoords = raw_data(cuvs),
                    normals = raw_data(dstn), indices = raw_data(cidx),
                }
                rl.UploadMesh(&mesh, true)
                append(prims, Skinned_Prim{mesh, mat, cn, cverts, cnrms, dst, dstn, cj, cw, owner, rm, skinned, dbl_side, cidx, cuvs, -1, nil})
            }
            MAXV :: 60000
            if n <= MAXV {
                cv := make([]int, n)
                for i in 0 ..< n { cv[i] = i }
                ci := make([]uint, nidx)
                for i in 0 ..< nidx { ci[i] = raw_idx[i] }
                emit_chunk(&f.prims, verts, nrms, uvs, all_joints, all_weights, cv, ci, mat, owner, rm, skinned, dbl)
                delete(cv); delete(ci)
            } else {
                remap := make([]int, n)
                for i in 0 ..< n { remap[i] = -1 }
                defer delete(remap)
                chunk_verts := make([dynamic]int)
                chunk_idx := make([dynamic]uint)
                ntri := nidx / 3
                for t in 0 ..< ntri {
                    need := 0
                    for k in 0 ..< 3 {
                        oi := int(raw_idx[t*3+k])
                        if remap[oi] >= 0 { continue }
                        dup := false
                        for mm in 0 ..< k {
                            if int(raw_idx[t*3+mm]) == oi { dup = true; break }
                        }
                        if !dup { need += 1 }
                    }
                    if len(chunk_verts) + need > MAXV && len(chunk_idx) > 0 {
                        emit_chunk(&f.prims, verts, nrms, uvs, all_joints, all_weights, chunk_verts[:], chunk_idx[:], mat, owner, rm, skinned, dbl)
                        for v in chunk_verts { remap[v] = -1 }
                        delete(chunk_verts); delete(chunk_idx)
                        chunk_verts = make([dynamic]int)
                        chunk_idx = make([dynamic]uint)
                    }
                    for k in 0 ..< 3 {
                        oi := int(raw_idx[t*3+k])
                        if remap[oi] < 0 {
                            remap[oi] = len(chunk_verts)
                            append(&chunk_verts, oi)
                        }
                        append(&chunk_idx, uint(remap[oi]))
                    }
                }
                if len(chunk_idx) > 0 {
                    emit_chunk(&f.prims, verts, nrms, uvs, all_joints, all_weights, chunk_verts[:], chunk_idx[:], mat, owner, rm, skinned, dbl)
                }
                delete(chunk_verts); delete(chunk_idx)
            }
            delete(raw_idx)
        }
    }

    // per-frame temps
    f.samp_t = make([][3]f32, nn)
    f.samp_r = make([][4]f32, nn)
    f.samp_s = make([][3]f32, nn)
    f.has_c  = make([]bool, nn)
    f.wsum   = make([]f32, nn)
    f.rec_t = make([][3]f32, nn)
    f.rec_r = make([][4]f32, nn)
    f.rec_blend = 1
    f.world = make([][16]f32, nn)
    f.palette = make([][16]f32, nj)
    f.bumper_pos = {0, 0, 0}
    f.atk_t = 9999
    f.atk_rate = 1.0
    f.run_rate = 1.0
    f.slope_up = {0, 1, 0}
    f.mode = .Anim
    f.do_anim = true
    f.prev_hp = f.max_hp
    f.hurt_f = -99999
    f.state = "idle"
    f.grounded = true
    f.mm_freeze = IDENT16
    f.mm_last = IDENT16
    f.render_mm = IDENT16
    f.handoff_age = -1
    // foot-IK chains: locate leg nodes, measure bind bone lengths (nodes
    // currently hold the scaled bind pose, so lengths are model meters)
    leg_names := [6]string{"mixamorig:LeftUpLeg", "mixamorig:LeftLeg", "mixamorig:LeftFoot", "mixamorig:RightUpLeg", "mixamorig:RightLeg", "mixamorig:RightFoot"}
    for li in 0 ..< 6 {
        f.leg_idx[li] = find_joint(data, leg_names[li])
    }
    if f.leg_idx[0] >= 0 && f.leg_idx[1] >= 0 && f.leg_idx[2] >= 0 &&
       f.leg_idx[3] >= 0 && f.leg_idx[4] >= 0 && f.leg_idx[5] >= 0 {
        bw0 := make([][16]f32, nn)
        defer delete(bw0)
        for i in 0 ..< nn {
            gltf.node_transform_world(&data.nodes[i], &bw0[i][0])
        }
        bp := proc(bw: [][16]f32, idx: int) -> [3]f32 {
            return {bw[idx][12], bw[idx][13], bw[idx][14]}
        }
        f.leg_len[0] = linalg.length(bp(bw0, f.leg_idx[1]) - bp(bw0, f.leg_idx[0]))
        f.leg_len[1] = linalg.length(bp(bw0, f.leg_idx[2]) - bp(bw0, f.leg_idx[1]))
        f.leg_len[2] = linalg.length(bp(bw0, f.leg_idx[4]) - bp(bw0, f.leg_idx[3]))
        f.leg_len[3] = linalg.length(bp(bw0, f.leg_idx[5]) - bp(bw0, f.leg_idx[4]))
        f.plant = {-1e9, -1e9}
        // ankle height above sole: ankle bind height minus lowest mesh vert
        min_y := f32(1e9)
        for &pr in f.prims {
            for i in 0 ..< pr.count {
                if pr.pos[i*3+1] < min_y { min_y = pr.pos[i*3+1] }
            }
        }
        ay := (bp(bw0, f.leg_idx[2]).y + bp(bw0, f.leg_idx[5]).y) * 0.5
        f.ankle_h = max(ay - min_y, 0.05)
    }
    return f
}

// rigid sword prop: loads assets/sword.glb once per fighter as an
// unskinned prim; render_fighter re-seats it on f.hand_node every frame
// from f.world, so it tracks anim AND ragdoll.
fighter_give_sword :: proc(f: ^Fighter, albedo_path, normal_path: string) {
    opts: gltf.options
    path := "../assets/sword.glb"
    data, res := gltf.parse_file(opts, cstring(raw_data(path)))
    assert(res == .success, "parse sword failed")
    assert(gltf.load_buffers(opts, data, cstring(raw_data(path))) == .success, "buffers sword failed")
    m := &data.meshes[0]
    p := &m.primitives[0]
    apos, anrm, auv: ^gltf.accessor
    for ai in 0 ..< len(p.attributes) {
        switch string(p.attributes[ai].name) {
        case "POSITION": apos = p.attributes[ai].data
        case "NORMAL": anrm = p.attributes[ai].data
        case "TEXCOORD_0": auv = p.attributes[ai].data
        }
    }
    assert(apos != nil && anrm != nil && auv != nil, "sword missing attribs")
    n := int(apos.count)
    verts := make([]f32, n * 3)
    nrms  := make([]f32, n * 3)
    uvs   := make([]f32, n * 2)
    for i in 0 ..< n {
        _ = gltf.accessor_read_float(apos, uint(i), &verts[i * 3], 3)
        _ = gltf.accessor_read_float(anrm, uint(i), &nrms[i * 3], 3)
        _ = gltf.accessor_read_float(auv,  uint(i), &uvs[i * 2], 2)
    }
    nidx := int(p.indices.count)
    cidx := make([]u16, nidx)
    for i in 0 ..< nidx { cidx[i] = u16(gltf.accessor_read_index(p.indices, uint(i))) }
    dst := make([]f32, n * 3)
    dstn := make([]f32, n * 3)
    copy(dst, verts)
    copy(dstn, nrms)
    mesh := rl.Mesh{
        vertexCount = c.int(n), triangleCount = c.int(nidx / 3),
        vertices = raw_data(dst), texcoords = raw_data(uvs),
        normals = raw_data(dstn), indices = raw_data(cidx),
    }
    rl.UploadMesh(&mesh, false)
    mat := rl.LoadMaterialDefault()
    if albedo_path != "" {
        rim := rl.LoadImage(cstring(raw_data(albedo_path)))
        if rim.data != nil {
            tex := rl.LoadTextureFromImage(rim)
            rl.UnloadImage(rim)
            if tex.id != 0 { rl.SetMaterialTexture(&mat, .ALBEDO, tex) }
        }
    }
    if normal_path != "" {
        nim := rl.LoadImage(cstring(raw_data(normal_path)))
        if nim.data != nil {
            ntex := rl.LoadTextureFromImage(nim)
            rl.UnloadImage(nim)
            if ntex.id != 0 { rl.SetMaterialTexture(&mat, .NORMAL, ntex) }
        }
    }
    mat.maps[0].color = rl.WHITE
    rm: [16]f32 = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
    append(&f.prims, Skinned_Prim{mesh, mat, n, verts, nrms, dst, dstn, nil, nil, f.hand_node, rm, false, true, nil, nil, -1, nil})
    f.sword_idx = len(f.prims) - 1
    f.has_sword = true
    fmt.printf("sword: %d verts on %s\n", n, "fighter" if f.is_player else "enemy")
}
