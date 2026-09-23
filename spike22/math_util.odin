package spike22

import "core:math"
import linalg "core:math/linalg"
import rl "vendor:raylib"
import gltf "vendor:cgltf"
// spike22 math: column-major matrix/quat helpers, rigid inverses, node pinning.
IDENT16: [16]f32 : {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

mul_col :: proc(a, b: [16]f32) -> [16]f32 {
    r: [16]f32
    for c in 0 ..< 4 {
        for r_ in 0 ..< 4 {
            s := f32(0)
            for k in 0 ..< 4 { s += a[k * 4 + r_] * b[c * 4 + k] }
            r[c * 4 + r_] = s
        }
    }
    return r
}

// general 4x4 inverse (column-major). Needed because a scaled bind's
// inverse-bind matrices must invert OUR bind worlds, not the file's.
mat4_inverse :: proc(m: [16]f32) -> [16]f32 {
    inv: [16]f32
    inv[0] = m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10]
    inv[4] = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10]
    inv[8] = m[4]*m[9]*m[15] - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9]
    inv[12] = -m[4]*m[9]*m[14] + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9]
    inv[1] = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10]
    inv[5] = m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10]
    inv[9] = -m[0]*m[9]*m[15] + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9]
    inv[13] = m[0]*m[9]*m[14] - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9]
    inv[2] = m[1]*m[6]*m[15] - m[1]*m[7]*m[14] - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7] - m[13]*m[3]*m[6]
    inv[6] = -m[0]*m[6]*m[15] + m[0]*m[7]*m[14] + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7] + m[12]*m[3]*m[6]
    inv[10] = m[0]*m[5]*m[15] - m[0]*m[7]*m[13] - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7] - m[12]*m[3]*m[5]
    inv[14] = -m[0]*m[5]*m[14] + m[0]*m[6]*m[13] + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6] + m[12]*m[2]*m[5]
    inv[3] = -m[1]*m[6]*m[11] + m[1]*m[7]*m[10] + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7] + m[9]*m[3]*m[6]
    inv[7] = m[0]*m[6]*m[11] - m[0]*m[7]*m[10] - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7] - m[8]*m[3]*m[6]
    inv[11] = -m[0]*m[5]*m[11] + m[0]*m[7]*m[9] + m[4]*m[1]*m[11] - m[4]*m[3]*m[9] - m[8]*m[1]*m[7] + m[8]*m[3]*m[5]
    inv[15] = m[0]*m[5]*m[10] - m[0]*m[6]*m[9] - m[4]*m[1]*m[10] + m[4]*m[2]*m[9] + m[8]*m[1]*m[6] - m[8]*m[2]*m[5]
    det := m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12]
    if det != 0 { det = 1.0 / det }
    for i in 0 ..< 16 { inv[i] *= det }
    return inv
}

to_rl :: proc(m: [16]f32) -> rl.Matrix {
    return rl.Matrix{
        m[0], m[4], m[8],  m[12],
        m[1], m[5], m[9],  m[13],
        m[2], m[6], m[10], m[14],
        m[3], m[7], m[11], m[15],
    }
}

slerp44 :: proc(a, b: [4]f32, f: f32) -> [4]f32 {
    dot := a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    bb := b
    if dot < 0 { dot = -dot; bb = -b }
    dot = math.clamp(dot, -1.0, 1.0)
    th := math.acos(dot)
    s0, s1: f32
    if th < 1e-4 { s0, s1 = 1 - f, f } else {
        s0 = math.sin((1 - f) * th) / math.sin(th)
        s1 = math.sin(f * th) / math.sin(th)
    }
    return a * s0 + bb * s1
}

inverse_rigid :: proc(m: [16]f32) -> [16]f32 {
    r: [16]f32
    r[0] = m[0]; r[1] = m[4]; r[2] = m[8];  r[3] = 0
    r[4] = m[1]; r[5] = m[5]; r[6] = m[9];  r[7] = 0
    r[8] = m[2]; r[9] = m[6]; r[10] = m[10]; r[11] = 0
    tx, ty, tz := m[12], m[13], m[14]
    r[12] = -(r[0]*tx + r[4]*ty + r[8]*tz)
    r[13] = -(r[1]*tx + r[5]*ty + r[9]*tz)
    r[14] = -(r[2]*tx + r[6]*ty + r[10]*tz)
    r[15] = 1
    return r
}

mat3_to_quat :: proc(m: [16]f32) -> [4]f32 {
    tr := m[0] + m[5] + m[10]
    q: [4]f32
    if tr > 0 {
        s := math.sqrt(tr + 1.0) * 2
        q[3] = 0.25 * s
        q[0] = (m[6] - m[9]) / s
        q[1] = (m[8] - m[2]) / s
        q[2] = (m[1] - m[4]) / s
    } else if m[0] > m[5] && m[0] > m[10] {
        s := math.sqrt(1.0 + m[0] - m[5] - m[10]) * 2
        q[3] = (m[6] - m[9]) / s
        q[0] = 0.25 * s
        q[1] = (m[1] + m[4]) / s
        q[2] = (m[8] + m[2]) / s
    } else if m[5] > m[10] {
        s := math.sqrt(1.0 + m[5] - m[0] - m[10]) * 2
        q[3] = (m[8] - m[2]) / s
        q[0] = (m[1] + m[4]) / s
        q[1] = 0.25 * s
        q[2] = (m[6] + m[9]) / s
    } else {
        s := math.sqrt(1.0 + m[10] - m[0] - m[5]) * 2
        q[3] = (m[1] - m[4]) / s
        q[0] = (m[8] + m[2]) / s
        q[1] = (m[6] + m[9]) / s
        q[2] = 0.25 * s
    }
    return q
}

find_node :: proc(data: ^gltf.data, name: string) -> int {
    for i in 0 ..< len(data.nodes) {
        if string(data.nodes[i].name) == name { return i }
    }
    return -1
}

parent_of :: proc(data: ^gltf.data, idx: int) -> int {
    p := data.nodes[idx].parent
    if p == nil { return -1 }
    for i in 0 ..< len(data.nodes) {
        if &data.nodes[i] == p { return i }
    }
    return -1
}

pin_node_world :: proc(data: ^gltf.data, idx: int, target: [16]f32, tmp: ^[16]f32) {
    pw := IDENT16
    p := parent_of(data, idx)
    if p >= 0 {
        gltf.node_transform_world(&data.nodes[p], &tmp[0])
        pw = tmp^
    }
    local := mul_col(inverse_rigid(pw), target)
    nd := &data.nodes[idx]
    nd.translation = {local[12], local[13], local[14]}
    nd.has_translation = true
    nd.rotation = mat3_to_quat(local)
    nd.has_rotation = true
}

// ---- small quat helpers for the IK pass ----
quat_mul :: proc(a, b: [4]f32) -> [4]f32 {
    return {
        a[3]*b[0] + a[0]*b[3] + a[1]*b[2] - a[2]*b[1],
        a[3]*b[1] - a[0]*b[2] + a[1]*b[3] + a[2]*b[0],
        a[3]*b[2] + a[0]*b[1] - a[1]*b[0] + a[2]*b[3],
        a[3]*b[3] - a[0]*b[0] - a[1]*b[1] - a[2]*b[2],
    }
}

quat_conj :: proc(a: [4]f32) -> [4]f32 { return {-a[0], -a[1], -a[2], a[3]} }

quat_rot_vec :: proc(q: [4]f32, v: [3]f32) -> [3]f32 {
    // v' = q v q* (q unit)
    t := [3]f32{2.0 * (q[1]*v[2] - q[2]*v[1]), 2.0 * (q[2]*v[0] - q[0]*v[2]), 2.0 * (q[0]*v[1] - q[1]*v[0])}
    return {v[0] + q[3]*t[0] + (q[1]*t[2] - q[2]*t[1]), v[1] + q[3]*t[1] + (q[2]*t[0] - q[0]*t[2]), v[2] + q[3]*t[2] + (q[0]*t[1] - q[1]*t[0])}
}

// shortest-arc rotation taking unit a to unit b
quat_from_vecs :: proc(a, b: [3]f32) -> [4]f32 {
    d := a.x*b.x + a.y*b.y + a.z*b.z
    if d > 0.999999 { return {0, 0, 0, 1} }
    if d < -0.999999 {
        // antiparallel: pick any orthogonal axis
        ax := [3]f32{1, 0, 0}
        if abs(a.x) > 0.9 { ax = {0, 1, 0} }
        o := linalg.normalize(linalg.cross(a, ax))
        return {o.x, o.y, o.z, 0}
    }
    c := linalg.cross(a, b)
    q := [4]f32{c.x, c.y, c.z, 1 + d}
    n := math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3])
    if n < 1e-9 { return {0, 0, 0, 1} }
    return q / n
}

// world-matrix rotation as unit quat (strips uniform file-unit scale)
quat_from_world :: proc(m: [16]f32) -> [4]f32 {
    s := math.sqrt(m[0]*m[0] + m[1]*m[1] + m[2]*m[2])
    if s < 1e-9 { return {0, 0, 0, 1} }
    u: [16]f32 = m
    for i in 0 ..< 11 { u[i] /= s }
    q := mat3_to_quat(u)
    n := math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3])
    if n < 1e-9 { return {0, 0, 0, 1} }
    return q / n
}

yaw_rot :: proc(v: [3]f32, yaw: f32) -> [3]f32 {
    cy, sy := math.cos(yaw), math.sin(yaw)
    return {cy*v.x + sy*v.z, v.y, -sy*v.x + cy*v.z}
}
