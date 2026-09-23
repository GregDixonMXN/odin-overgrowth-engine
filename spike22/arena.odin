package spike22

import "core:fmt"
import "core:math"
import "core:c"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import gltf "vendor:cgltf"
import jph "../thirdparty/joltc-odin"
// spike22 arena: building props + AABB colliders, vault + wall jump.
// Collision is boxes only (axis-aligned placements); meshes are decor.
// Bumper logic uses ground_at (terrain + standable tops) + arena_pushout
// (sides). Jolt gets static twins so ragdolls/crates collide too.

Arena_Box :: struct { lo, hi: [3]f32 } // world AABB
Arena_Prop :: struct {
    mesh: rl.Mesh,
    mat:  rl.Material,
    pos:  [3]f32,
    size: [3]f32, // non-1 for generated masses (cube scaled to the pad)
    dbl:  bool, // disable backface culling (suspect winding)
    flip: bool, // flip triangle winding at emit (inside-out exporter)
}
Arena :: struct {
    boxes: [dynamic]Arena_Box,
    props: [dynamic]Arena_Prop,
}

// single arena, set once at load (recovery paths have no ctx to thread)
g_arena: ^Arena

// standable surface: terrain, plus any box top at/below feet+step.
// feet=1e9 snaps to the topmost surface (spawns/respawns).
ground_at :: proc(hf: ^Heightfield, x, z, feet: f32) -> (f32, bool) {
    best := f32(-1e9)
    ok := false
    if h, ok2 := height_at(hf, x, z); ok2 {
        best = h
        ok = true
    }
    ar := g_arena
    if ar != nil {
        for b in ar.boxes {
            if x >= b.lo.x && x <= b.hi.x && z >= b.lo.z && z <= b.hi.z {
                if b.hi.y <= feet + 0.7 && b.hi.y > best {
                    best = b.hi.y
                    ok = true
                }
            }
        }
    }
    return best, ok
}

// sides: push the bumper out, report which box + outward normal.
// Feet above top-0.25 = standing on it (no push). Returns hit=-1 if free.
arena_pushout :: proc(pos: [3]f32, feet: f32) -> ([3]f32, int, [3]f32) {
    r := f32(0.35)
    ar := g_arena
    if ar != nil {
        for bi in 0 ..< len(ar.boxes) {
            b := &ar.boxes[bi]
            if feet < b.lo.y - 0.5 || feet > b.hi.y - 0.25 { continue }
            if pos.x > b.lo.x - r && pos.x < b.hi.x + r && pos.z > b.lo.z - r && pos.z < b.hi.z + r {
                dx1 := pos.x - (b.lo.x - r)
                dx2 := (b.hi.x + r) - pos.x
                dz1 := pos.z - (b.lo.z - r)
                dz2 := (b.hi.z + r) - pos.z
                p := pos
                n := [3]f32{}
                if dx1 <= dx2 && dx1 <= dz1 && dx1 <= dz2 {
                    p.x = b.lo.x - r
                    n = {-1, 0, 0}
                } else if dx2 <= dz1 && dx2 <= dz2 {
                    p.x = b.hi.x + r
                    n = {1, 0, 0}
                } else if dz1 <= dz2 {
                    p.z = b.lo.z - r
                    n = {0, 0, -1}
                } else {
                    p.z = b.hi.z + r
                    n = {0, 0, 1}
                }
                return p, bi, n
            }
        }
    }
    return pos, -1, [3]f32{}
}

// ledge grab: falling past a box lip, close, drifting into it -> catch.
// Returns box index + face (0:-x 1:+x 2:-z 3:+z). Hands catch tops
// [feet+0.3, feet+1.7]; stand-off band keeps fingers on the lip.
arena_ledge_grab :: proc(pos, vel: [3]f32, vy: f32) -> (int, int, bool) {
    if vy > -0.5 { return 0, 0, false }
    ar := g_arena
    if ar == nil { return 0, 0, false }
    for bi in 0 ..< len(ar.boxes) {
        b := &ar.boxes[bi]
        dy := b.hi.y - pos.y
        if dy < 0.3 || dy > 1.7 { continue }
        if pos.y < b.lo.y - 0.5 { continue } // below the mass, nothing to catch
        // +x face (fighter east of the box, moving west)
        if pos.x >= b.hi.x + 0.2 && pos.x <= b.hi.x + 0.9 && pos.z >= b.lo.z - 0.3 && pos.z <= b.hi.z + 0.3 && vel.x < -0.5 {
            return bi, 1, true
        }
        // -x face
        if pos.x <= b.lo.x - 0.2 && pos.x >= b.lo.x - 0.9 && pos.z >= b.lo.z - 0.3 && pos.z <= b.hi.z + 0.3 && vel.x > 0.5 {
            return bi, 0, true
        }
        // +z face
        if pos.z >= b.hi.z + 0.2 && pos.z <= b.hi.z + 0.9 && pos.x >= b.lo.x - 0.3 && pos.x <= b.hi.x + 0.3 && vel.z < -0.5 {
            return bi, 3, true
        }
        // -z face
        if pos.z <= b.lo.z - 0.2 && pos.z >= b.lo.z - 0.9 && pos.x >= b.lo.x - 0.3 && pos.x <= b.hi.x + 0.3 && vel.z > 0.5 {
            return bi, 2, true
        }
    }
    return 0, 0, false
}

// hang mount: pull inside the lip, pop up; ground-stick lands the top.
arena_hang_mount :: proc(f: ^Fighter, ctx: ^Ctx) {
    ar := g_arena
    if ar == nil || f.hang_box < 0 || f.hang_box >= len(ar.boxes) { f.hanging = false; return }
    b := &ar.boxes[f.hang_box]
    switch f.hang_face {
    case 0: f.bumper_pos.x = b.lo.x + 0.6
    case 1: f.bumper_pos.x = b.hi.x - 0.6
    case 2: f.bumper_pos.z = b.lo.z + 0.6
    case 3: f.bumper_pos.z = b.hi.z - 0.6
    }
    f.bumper_pos.y = b.hi.y + 0.3
    f.vy = 2.5; f.grounded = false; f.air_t = 0
    f.hanging = false
    f.vault_cd = 0.4
    sfx_playi(SFXW_VAULT)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d HANGUP\n", ctx.frame)
    }
}
// pop up with forward carry onto the top. Returns true if vaulted.
arena_try_vault :: proc(f: ^Fighter, ctx: ^Ctx, hit: int, n: [3]f32) -> bool {
    // no cooldown needed: a vault always leaves the ground, so it can't
    // refire until you land again (walljump carries the only cd)
    if hit < 0 || f.dying { return false }
    ar := g_arena
    if ar == nil { return false }
    top := ar.boxes[hit].hi.y
    feet := f.bumper_pos.y
    if top < feet + 0.7 || top > feet + 2.7 { return false }
    want_up := ctx.auto || !f.is_player
    if f.is_player && !ctx.auto {
        want_up = rl.IsKeyDown(.SPACE) || pad_jump_down()
    }
    if !want_up { return false }
    f.vy = 9.0
    f.grounded = false
    f.air_t = 0
    f.roll_t = 0 // walljump breaks the tumble
    f.bumper_vel.x = -n.x * 4.0
    f.bumper_vel.z = -n.z * 4.0
    sfx_playi(SFXW_VAULT)
    if ctx.auto || f.is_player {
        fmt.printf("f=%d VAULT\n", ctx.frame)
    }
    return true
}

// wall jump: airborne, SPACE, within 0.8m of a box side, feet below
// top-0.4 -> launch off the wall. Player/AI manual; auto demo skips it.
arena_try_walljump :: proc(f: ^Fighter, ctx: ^Ctx) -> bool {
    if f.grounded || f.vault_cd > 0 || f.dying { return false }
    ar := g_arena
    if ar == nil { return false }
    feet := f.bumper_pos.y
    for b in ar.boxes {
        if feet < b.lo.y || feet > b.hi.y - 0.4 { continue }
        // closest point on the rect, horizontal
        cx := math.clamp(f.bumper_pos.x, b.lo.x, b.hi.x)
        cz := math.clamp(f.bumper_pos.z, b.lo.z, b.hi.z)
        dx := f.bumper_pos.x - cx
        dz := f.bumper_pos.z - cz
        d2 := dx * dx + dz * dz
        if d2 < 0.8 * 0.8 && d2 > 1e-8 {
            d := math.sqrt(d2)
            f.bumper_vel.x = dx / d * 7.0
            f.bumper_vel.z = dz / d * 7.0
            f.vy = 7.0
            f.vault_cd = 0.4
            f.roll_t = 0 // leaving ground breaks the tumble
            sfx_playi(SFXW_VAULT)
            if ctx.auto || f.is_player {
                fmt.printf("f=%d WALLJUMP\n", ctx.frame)
            }
            return true
        }
    }
    return false
}

arena_point_blocked :: proc(p: [3]f32) -> bool {
    ar := g_arena
    if ar == nil { return false }
    for b in ar.boxes {
        if p.x > b.lo.x - 0.4 && p.x < b.hi.x + 0.4 && p.z > b.lo.z - 0.4 && p.z < b.hi.z + 0.4 && p.y > b.lo.y - 0.4 && p.y < b.hi.y + 0.4 {
            return true
        }
    }
    return false
}

arena_render :: proc(ar: ^Arena) {
    for pr in ar.props {
        // rigid prop: translate to pad, scale for generated masses
        mm: [16]f32 = {pr.size.x, 0, 0, 0, 0, pr.size.y, 0, 0, 0, 0, pr.size.z, 0, pr.pos.x, pr.pos.y, pr.pos.z, 1}
        rlgl.DisableColorBlend()
        if pr.dbl { rlgl.DisableBackfaceCulling() }
        rl.DrawMesh(pr.mesh, pr.mat, to_rl(mm))
        if pr.dbl { rlgl.EnableBackfaceCulling() }
        rlgl.EnableColorBlend()
    }
}

arena_tex :: proc(mat: ^rl.Material, slot: rl.MaterialMapIndex, path: string) {
    if path == "" { return }
    im := rl.LoadImage(cstring(raw_data(path)))
    if im.data == nil { return }
    tex := rl.LoadTextureFromImage(im)
    rl.UnloadImage(im)
    if tex.id != 0 { rl.SetMaterialTexture(mat, slot, tex) }
}

// dim self-light so steep unlit faces (pagoda roofs) read instead of
// going pure black. Reuses the albedo as the emission map.
arena_emissive :: proc(mat: ^rl.Material, albedo_path: string, amt: u8) {
    if albedo_path == "" { return }
    im := rl.LoadImage(cstring(raw_data(albedo_path)))
    if im.data == nil { return }
    tex := rl.LoadTextureFromImage(im)
    rl.UnloadImage(im)
    if tex.id == 0 { return }
    rl.SetMaterialTexture(mat, .EMISSION, tex)
    mat.maps[int(rl.MaterialMapIndex.EMISSION)].color = {amt, amt, amt, 255}
}

arena_add :: proc(ar: ^Arena, bi: ^jph.BodyInterface, glb_path, tint_desc: string, tint: rl.Color, pos, minb, maxb: [3]f32, albedo_path := "", normal_path := "", rough_path := "", metal_path := "", occ_path := "", dbl_side := false, flip_winding := false, emit_amt := u8(0), flip_nrm := false) {
    _ = tint_desc
    // NOTE: raylib's LoadModel segfaults uploading these Blender glbs, so
    // buildings ride the same hand-rolled prim path as fighters/swords.
    opts: gltf.options
    data, res := gltf.parse_file(opts, cstring(raw_data(glb_path)))
    assert(res == .success, "parse prop failed")
    assert(gltf.load_buffers(opts, data, cstring(raw_data(glb_path))) == .success, "buffers prop failed")
    for mi in 0 ..< len(data.meshes) {
        m := &data.meshes[mi]
        for pi in 0 ..< len(m.primitives) {
            p := &m.primitives[pi]
            // skip toon outline shells (inverted-hull "Outline" prims render
            // as black silhouettes around the real building)
            if p.material != nil {
                mn := string(p.material.name)
                is_outline := false
                for i in 0 ..< len(mn) - 6 {
                    if mn[i] == 'u' && mn[i + 1] == 't' && mn[i + 2] == 'l' && mn[i + 3] == 'i' && mn[i + 4] == 'n' && mn[i + 5] == 'e' { is_outline = true; break }
                }
                if is_outline { continue }
            }
            apos, anrm, auv: ^gltf.accessor
            for ai in 0 ..< len(p.attributes) {
                switch string(p.attributes[ai].name) {
                case "POSITION": apos = p.attributes[ai].data
                case "NORMAL": anrm = p.attributes[ai].data
                case "TEXCOORD_0": auv = p.attributes[ai].data
                }
            }
            if apos == nil || anrm == nil { continue }
            n := int(apos.count)
            verts := make([]f32, n * 3)
            nrms  := make([]f32, n * 3)
            for i in 0 ..< n {
                _ = gltf.accessor_read_float(apos, uint(i), &verts[i * 3], 3)
                _ = gltf.accessor_read_float(anrm, uint(i), &nrms[i * 3], 3)
                if flip_nrm {
                    // some author packs point slabs' normals down
                    nrms[i * 3] = -nrms[i * 3]
                    nrms[i * 3 + 1] = -nrms[i * 3 + 1]
                    nrms[i * 3 + 2] = -nrms[i * 3 + 2]
                }
            }
            uvs := make([]f32, n * 2)
            if auv != nil {
                for i in 0 ..< n {
                    _ = gltf.accessor_read_float(auv, uint(i), &uvs[i * 2], 2)
                }
            }
            nidx := int(p.indices.count)
            cidx := make([]u16, nidx)
            for i in 0 ..< nidx { cidx[i] = u16(gltf.accessor_read_index(p.indices, uint(i))) }
            if flip_winding {
                // inside-out exporter (same family as the terrain flip):
                // swap index order per triangle
                for t in 0 ..< nidx / 3 {
                    cidx[t * 3], cidx[t * 3 + 2] = cidx[t * 3 + 2], cidx[t * 3]
                }
            }
            mesh := rl.Mesh{
                vertexCount = c.int(n), triangleCount = c.int(nidx / 3),
                vertices = raw_data(verts), texcoords = raw_data(uvs),
                normals = raw_data(nrms), indices = raw_data(cidx),
            }
            rl.UploadMesh(&mesh, false)
            mat := rl.LoadMaterialDefault()
            arena_tex(&mat, .ALBEDO, albedo_path)
            arena_tex(&mat, .NORMAL, normal_path)
            arena_tex(&mat, .ROUGHNESS, rough_path)
            arena_tex(&mat, .METALNESS, metal_path)
            arena_tex(&mat, .OCCLUSION, occ_path)
            if albedo_path == "" { mat.maps[0].color = tint }
            if emit_amt > 0 { arena_emissive(&mat, albedo_path, emit_amt) }
            append(&ar.props, Arena_Prop{mesh, mat, pos, {1, 1, 1}, dbl_side, flip_winding})
        }
    }
    lo := pos + minb
    hi := pos + maxb
    append(&ar.boxes, Arena_Box{lo, hi})
    // Jolt static twin (ragdolls + crates collide with the mass)
    he := jph.Vec3{(hi.x - lo.x) * 0.5, (hi.y - lo.y) * 0.5, (hi.z - lo.z) * 0.5}
    shape := jph.BoxShapeSettings_CreateShape(jph.BoxShapeSettings_Create(&he, 0.05))
    center := jph.RVec3{(lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5}
    ident: jph.Quat = 1
    cs := jph.BodyCreationSettings_Create3(cast(^jph.Shape)shape, &center, &ident, .Static, OBJECT_LAYER_NON_MOVING)
    jph.BodyInterface_CreateAndAddBody(bi, cs, .DontActivate)
    jph.BodyCreationSettings_Destroy(cs)
    fmt.printf("arena box lo=(%.1f %.1f %.1f) hi=(%.1f %.1f %.1f)\n", lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
}

// generated fallback mass: guaranteed-clean cube on a collision pad
// (for author meshes whose normals/lighting refuse to cooperate)
arena_add_cube :: proc(ar: ^Arena, bi: ^jph.BodyInterface, pos, minb, maxb: [3]f32, tint: rl.Color) {
    mesh := rl.GenMeshCube(1, 1, 1)
    rl.UploadMesh(&mesh, false)
    mat := rl.LoadMaterialDefault()
    mat.maps[0].color = tint
    lo := pos + minb
    hi := pos + maxb
    center := (lo + hi) * 0.5
    size := hi - lo
    append(&ar.props, Arena_Prop{mesh, mat, center, size, false, false})
    he := jph.Vec3{(hi.x - lo.x) * 0.5, (hi.y - lo.y) * 0.5, (hi.z - lo.z) * 0.5}
    centerj := jph.RVec3{(lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5}
    shape := jph.BoxShapeSettings_CreateShape(jph.BoxShapeSettings_Create(&he, 0.05))
    ident: jph.Quat = 1
    cs := jph.BodyCreationSettings_Create3(cast(^jph.Shape)shape, &centerj, &ident, .Static, OBJECT_LAYER_NON_MOVING)
    jph.BodyInterface_CreateAndAddBody(bi, cs, .DontActivate)
    jph.BodyCreationSettings_Destroy(cs)
    append(&ar.boxes, Arena_Box{lo, hi})
    fmt.printf("arena cube lo=(%.1f %.1f %.1f) hi=(%.1f %.1f %.1f)\n", lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
}
load_arena :: proc(bi: ^jph.BodyInterface, hf: ^Heightfield) -> Arena {
    ar: Arena
    ghut, _ := height_at(hf, -2, 9)
    ga, _ := height_at(hf, -17, 16)
    gb, _ := height_at(hf, 17, 16)
    gt, _ := height_at(hf, 3, 24)
    A :: "../assets/"
    T :: "../assets/"
    // hut villa: walls keep the brick set; slabs got planar UVs into the
    // set's clean plaster band (they sampled black voids before). Same pad.
    arena_add(&ar, bi, A + "hut_walls.glb", "hut", {150, 110, 80, 255}, {-2, ghut - 1.5, 9}, {-2.89, -0.05, -1.66}, {2.89, 3.59, 1.66}, T + "stylizedbuilding_base.png", T + "stylizedbuilding_nor.png", T + "stylizedbuilding_rough.png", T + "stylizedbuilding_metal.png", T + "stylizedbuilding_occ.png")
    arena_add(&ar, bi, A + "hut_slabs.glb", "slabs", {165, 160, 150, 255}, {-2, ghut - 1.5, 9}, {-2.89, -0.05, -1.66}, {2.89, 3.59, 1.66}, T + "stylizedbuilding_base.png", T + "stylizedbuilding_nor.png", T + "stylizedbuilding_rough.png", T + "stylizedbuilding_metal.png", T + "stylizedbuilding_occ.png")
    // west mass
    arena_add(&ar, bi, A + "build_a.glb", "blockA", {170, 150, 125, 255}, {-17, ga - 0.2, 16}, {-10.375, 0, -5.375}, {10.375, 16.1, 10.375}, T + "buildingA_albedo.png", T + "buildA_normal.png")
    // east depot (building1, brightened albedo, outline shells skipped)
    arena_add(&ar, bi, A + "build_b.glb", "depot", {120, 125, 135, 255}, {17, gb + 0.3, 16}, {-4.96, -8.94, -6.42}, {10.94, 1.63, 3.23}, T + "building1_base.png", T + "building1_nor.png", T + "building1_rough.png", "", T + "building1_occ.png")
    // pillar: cutthroat perch (dives in when you close) — no textures found, flat stays
    arena_add(&ar, bi, A + "tower.glb", "tower", {100, 100, 110, 255}, {3, gt, 24}, {-0.64, -0.05, -0.64}, {0.64, 15.59, 0.64})
    return ar
}
