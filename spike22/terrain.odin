package spike22

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "core:c"
import rl "vendor:raylib"
import gltf "vendor:cgltf"
import jph "../thirdparty/joltc-odin"
// spike22 terrain: heightfield bake/query, landscape load.
Heightfield :: struct { n: int, half: f32, cell: f32, h: []f32 }

// terrain normal via central differences (world space, unit)
height_normal :: proc(hf: ^Heightfield, x, z: f32) -> ([3]f32, bool) {
    e := hf.cell
    hx1, ok1 := height_at(hf, x + e, z)
    hx0, ok0 := height_at(hf, x - e, z)
    hz1, ok3 := height_at(hf, x, z + e)
    hz0, ok2 := height_at(hf, x, z - e)
    if !ok1 || !ok0 || !ok3 || !ok2 { return {0, 1, 0}, false }
    n := [3]f32{-(hx1 - hx0) / (2 * e), 1, -(hz1 - hz0) / (2 * e)}
    return linalg.normalize(n), true
}

height_at :: proc(hf: ^Heightfield, x, z: f32) -> (f32, bool) {
    // NaN queries (a bad bone probe, a buried body) fail soft instead of
    // indexing garbage and taking the whole match down with them.
    if x != x || z != z { fmt.printf("NANHF x=%v z=%v\n", x, z); return 0, false }
    if math.abs(x) >= hf.half || math.abs(z) >= hf.half { return 0, false }
    gx := (x + hf.half) / hf.cell
    gz := (z + hf.half) / hf.cell
    x0 := int(math.floor(gx)); z0 := int(math.floor(gz))
    x1 := min(x0 + 1, hf.n - 1); z1 := min(z0 + 1, hf.n - 1)
    fx := gx - f32(x0); fz := gz - f32(z0)
    h00 := hf.h[x0 * hf.n + z0]; h10 := hf.h[x1 * hf.n + z0]
    h01 := hf.h[x0 * hf.n + z1]; h11 := hf.h[x1 * hf.n + z1]
    return h00 * (1 - fx) * (1 - fz) + h10 * fx * (1 - fz) + h01 * (1 - fx) * fz + h11 * fx * fz, true
}

// rasterize every triangle into the grid (top surface wins), then relax holes
bake_heightfield :: proc(verts: []jph.Vec3, tris: []jph.IndexedTriangle) -> Heightfield {
    n := 512
    half := f32(500)
    cell := 2 * half / f32(n - 1)
    h := make([]f32, n * n)
    for i in 0 ..< n * n { h[i] = -1e9 }
    to_cell := proc(v, half, cell: f32, n: int) -> int {
        c := int((v + half) / cell)
        if c < 0 { return 0 }
        if c > n - 1 { return n - 1 }
        return c
    }
    edge :: proc(px, pz, ax, az, bx, bz: f32) -> f32 {
        return (px - ax) * (bz - az) - (pz - az) * (bx - ax)
    }
    for t in tris {
        a := verts[t.i1]; b := verts[t.i2]; c := verts[t.i3]
        area := edge(a.x, a.z, b.x, b.z, c.x, c.z)
        if math.abs(area) < 1e-9 { continue }
        ix0 := to_cell(min(min(a.x, b.x), c.x), half, cell, n)
        ix1 := to_cell(max(max(a.x, b.x), c.x), half, cell, n)
        iz0 := to_cell(min(min(a.z, b.z), c.z), half, cell, n)
        iz1 := to_cell(max(max(a.z, b.z), c.z), half, cell, n)
        for ix in ix0 ..= ix1 {
            for iz in iz0 ..= iz1 {
                px := -half + f32(ix) * cell
                pz := -half + f32(iz) * cell
                w0 := edge(px, pz, b.x, b.z, c.x, c.z) / area
                w1 := edge(px, pz, c.x, c.z, a.x, a.z) / area
                w2 := edge(px, pz, a.x, a.z, b.x, b.z) / area
                if w0 >= -1e-6 && w1 >= -1e-6 && w2 >= -1e-6 {
                    y := w0 * a.y + w1 * b.y + w2 * c.y
                    idx := ix * n + iz
                    if y > h[idx] { h[idx] = y }
                }
            }
        }
    }
    // relax unset cells from set neighbors
    for pass in 0 ..< 60 {
        changed := false
        for ix in 1 ..< n - 1 {
            for iz in 1 ..< n - 1 {
                idx := ix * n + iz
                if h[idx] > -1e8 { continue }
                s, cnt := f32(0), 0
                if h[idx - n] > -1e8 { s += h[idx - n]; cnt += 1 }
                if h[idx + n] > -1e8 { s += h[idx + n]; cnt += 1 }
                if h[idx - 1] > -1e8 { s += h[idx - 1]; cnt += 1 }
                if h[idx + 1] > -1e8 { s += h[idx + 1]; cnt += 1 }
                if cnt > 0 { h[idx] = s / f32(cnt); changed = true }
            }
        }
        if !changed { break }
    }
    // any leftovers get the global mean
    s, cnt := f32(0), 0
    for v in h { if v > -1e8 { s += v; cnt += 1 } }
    mean := s / f32(max(cnt, 1))
    filled, tot := 0, 0
    for i in 0 ..< n * n { if h[i] <= -1e8 { h[i] = mean; filled += 1 }; tot += 1 }
    // coverage along the play corridor (x +-15, z -10..60)
    corridor_unset := 0
    for ix in 0 ..< n {
        for iz in 0 ..< n {
            wx := -half + f32(ix) * cell
            wz := -half + f32(iz) * cell
            if math.abs(wx) < 15.0 && wz > -10.0 && wz < 60.0 {
                if h[ix * n + iz] == mean { corridor_unset += 1 }
            }
        }
    }
    fmt.printf("heightfield %dx%d cell=%.2fm unset-filled=%d/%d corridor-mean=%d mean=%.2f\n", n, n, cell, filled, tot, corridor_unset, mean)
    return {n, half, cell, h}
}

Terrain :: struct { mesh: rl.Mesh, mat: rl.Material, hf: Heightfield }

// landscape.glb is Z-up (Blender): rotate to Y-up for render + physics
load_terrain :: proc(path: string, bi: ^jph.BodyInterface) -> Terrain {
    t: Terrain
    opts: gltf.options
    data, res := gltf.parse_file(opts, cstring(raw_data(path)))
    assert(res == .success, "parse terrain failed")
    defer gltf.free(data)
    assert(gltf.load_buffers(opts, data, cstring(raw_data(path))) == .success, "terrain buffers failed")
    p := &data.meshes[0].primitives[0]
    find := proc(p: ^gltf.primitive, want: string) -> ^gltf.accessor {
        for ai in 0 ..< len(p.attributes) {
            if string(p.attributes[ai].name) == want { return p.attributes[ai].data }
        }
        return nil
    }
    apos := find(p, "POSITION")
    anrm := find(p, "NORMAL")
    auv  := find(p, "TEXCOORD_0")
    assert(apos != nil && anrm != nil, "terrain missing attribs")
    n := int(apos.count)
    assert(n < 60000, "terrain too big for u16")
    verts := make([]jph.Vec3, n) // kept alive: render mesh + physics alias it
    nrms  := make([]f32, n * 3)
    uvs   := make([]f32, n * 2)
    for i in 0 ..< n {
        v: [3]f32
        _ = gltf.accessor_read_float(apos, uint(i), &v[0], 3)
        verts[i] = {v.x, v.z, -v.y}
        if anrm != nil {
            _ = gltf.accessor_read_float(anrm, uint(i), &v[0], 3)
            nrms[i*3] = v.x; nrms[i*3+1] = v.z; nrms[i*3+2] = -v.y
        }
        if auv != nil {
            uv: [2]f32
            _ = gltf.accessor_read_float(auv, uint(i), &uv[0], 2)
            uvs[i*2] = uv.x; uvs[i*2+1] = uv.y
        }
    }
    nidx := int(p.indices.count)
    idx := make([]u16, nidx)
    tris := make([]jph.IndexedTriangle, nidx / 3)
    for i in 0 ..< nidx {
        idx[i] = u16(gltf.accessor_read_index(p.indices, uint(i)))
    }
    // Blender export came out wound CW; flip to CCW front faces
    for k in 0 ..< nidx / 3 {
        a, b, c := idx[k*3], idx[k*3+1], idx[k*3+2]
        idx[k*3], idx[k*3+1], idx[k*3+2] = c, b, a
        tris[k] = {u32(c), u32(b), u32(a), 0, 0}
    }
    t.mesh = rl.Mesh{
        vertexCount = c.int(n), triangleCount = c.int(nidx / 3),
        vertices = cast(^f32)raw_data(verts), texcoords = raw_data(uvs),
        normals = raw_data(nrms), indices = raw_data(idx),
    }
    rl.UploadMesh(&t.mesh, false)
    t.mat = rl.LoadMaterialDefault()
    {
        alb := rl.LoadImage("../assets/land_albedo.png")
        if alb.data != nil {
            tx := rl.LoadTextureFromImage(alb)
            rl.UnloadImage(alb)
            if tx.id != 0 {
                rl.SetMaterialTexture(&t.mat, .ALBEDO, tx)
                fmt.printf("terrain albedo %dx%d\n", tx.width, tx.height)
            }
        }
        nor := rl.LoadImage("../assets/land_normal.png")
        if nor.data != nil {
            tx := rl.LoadTextureFromImage(nor)
            rl.UnloadImage(nor)
            if tx.id != 0 {
                rl.SetMaterialTexture(&t.mat, .NORMAL, tx)
                fmt.printf("terrain normal %dx%d\n", tx.width, tx.height)
            }
        }
    }
    t.hf = bake_heightfield(verts, tris)
    // static collision twin
    shape := jph.MeshShapeSettings_CreateShape(jph.MeshShapeSettings_Create2(&verts[0], u32(n), &tris[0], u32(nidx / 3)))
    ident: jph.Quat = 1
    pos0 := jph.RVec3{0, 0, 0}
    cs := jph.BodyCreationSettings_Create3(cast(^jph.Shape)shape, &pos0, &ident, .Static, OBJECT_LAYER_NON_MOVING)
    jph.BodyInterface_CreateAndAddBody(bi, cs, .DontActivate)
    jph.BodyCreationSettings_Destroy(cs)
    delete(tris)
    fmt.printf("terrain verts=%d tris=%d\n", n, nidx / 3)
    return t
}
