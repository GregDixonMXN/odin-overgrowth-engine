package spike22

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import gltf "vendor:cgltf"
import jph "../thirdparty/joltc-odin"
// spike22 ragdoll: body tables, ragdoll build, handoff/recover/respawn, shape springs.
OBJECT_LAYER_NON_MOVING :: jph.ObjectLayer(0)
OBJECT_LAYER_MOVING     :: jph.ObjectLayer(1)

// body table: pin joint, parent body (-1 = free root), constraint pivot joint,
// far joint for sizing ("" = blob at pin joint), capsule radius.
RB_N :: 11
RB_PIN   := [RB_N]string{"mixamorig:Hips", "mixamorig:Spine1", "mixamorig:Head", "mixamorig:LeftUpLeg", "mixamorig:RightUpLeg", "mixamorig:LeftLeg", "mixamorig:RightLeg", "mixamorig:LeftArm", "mixamorig:RightArm", "mixamorig:LeftForeArm", "mixamorig:RightForeArm"}
RB_PARENT:= [RB_N]int{-1, 0, 1, 0, 0, 3, 4, 1, 1, 7, 8}
RB_PIVOT := [RB_N]string{"", "mixamorig:Spine1", "mixamorig:Neck", "mixamorig:LeftUpLeg", "mixamorig:RightUpLeg", "mixamorig:LeftLeg", "mixamorig:RightLeg", "mixamorig:LeftArm", "mixamorig:RightArm", "mixamorig:LeftForeArm", "mixamorig:RightForeArm"}
RB_FAR   := [RB_N]string{"", "", "", "mixamorig:LeftLeg", "mixamorig:RightLeg", "mixamorig:LeftFoot", "mixamorig:RightFoot", "mixamorig:LeftForeArm", "mixamorig:RightForeArm", "mixamorig:LeftHand", "mixamorig:RightHand"}
RB_RAD   := [RB_N]f32{0.30, 0.26, 0.20, 0.15, 0.15, 0.12, 0.12, 0.10, 0.10, 0.09, 0.09}
// active-ragdoll match strengths per body (pelvis leads free)
ACT_STR := [RB_N]f32{0.0, 0.25, 0.20, 0.15, 0.15, 0.10, 0.10, 0.15, 0.15, 0.10, 0.10}

// handoff velocity offsets per body: limbs thrown outward ballistically
KICK := [RB_N][3]f32{{0, 0, 0}, {0, 0.5, 0}, {-0.5, 1.5, 0.5}, {0.8, 0, -0.5}, {-0.8, 0, -0.5}, {1.2, -0.3, -1.0}, {-1.2, -0.3, -1.0}, {2.0, 0.5, 0}, {-2.0, 0.5, 0}, {2.5, 0, -0.5}, {-2.5, 0, -0.5}}
// SwingTwist limits per body {cone, twistMin, twistMax} (radians). Index 0
// (pelvis root) unused. Spine stiff, head moderate, shoulders/hips wide,
// elbows/knees tight — sprawl without folding into a ball.
ST_LIM := [RB_N][3]f32{
    {0, 0, 0},
    {0.40, -0.5, 0.5},  // spine
    {0.50, -0.8, 0.8},  // head
    {0.70, -0.7, 0.7},  // hips L/R
    {0.70, -0.7, 0.7},
    {0.30, -0.4, 0.4},  // knees
    {0.30, -0.4, 0.4},
    {0.70, -0.7, 0.7},  // shoulders L/R
    {0.70, -0.7, 0.7},
    {0.30, -0.4, 0.4},  // elbows
    {0.30, -0.4, 0.4},
}

make_ragdoll :: proc(f: ^Fighter, bi: ^jph.BodyInterface, physics: ^jph.PhysicsSystem, self_filter: ^jph.GroupFilterTable, fi: int) {
    data := f.data
    nn := f.nn
    bindw := make([][16]f32, nn)
    defer delete(bindw)
    for i in 0 ..< nn {
        gltf.node_transform_world(&data.nodes[i], &bindw[i][0])
    }
    bpos := proc(bindw: [][16]f32, idx: int) -> [3]f32 {
        return {bindw[idx][12], bindw[idx][13], bindw[idx][14]}
    }
    for b in 0 ..< RB_N {
        f.rb_node[b] = find_joint(data, RB_PIN[b])
        assert(f.rb_node[b] >= 0, "rb pin joint missing")
    }
    hips_b := bpos(bindw, f.rb_node[0])
    spine_b := bpos(bindw, f.rb_node[1])
    leg_span := spine_b.y - hips_b.y
    ident : jph.Quat = 1
    for b in 0 ..< RB_N {
        hh := f32(0.08)
        if b == 0 {
            f.rb_bind[b] = hips_b
            hh = math.clamp(0.5 * leg_span, 0.15, 0.45)
        } else if b == 1 {
            f.rb_bind[b] = spine_b
            hh = math.clamp(0.5 * leg_span, 0.15, 0.40)
        } else if RB_FAR[b] == "" {
            f.rb_bind[b] = bpos(bindw, f.rb_node[b])
        } else {
            fb := find_joint(data, RB_FAR[b])
            assert(fb >= 0, "rb far joint missing")
            tp := bpos(bindw, f.rb_node[b])
            bp := bpos(bindw, fb)
            f.rb_bind[b] = (tp + bp) * 0.5
            hh = math.max(0.5 * linalg.length(tp - bp) - RB_RAD[b], 0.05)
        }
        shape := jph.CapsuleShapeSettings_CreateShape(jph.CapsuleShapeSettings_Create(hh, RB_RAD[b]))
        c := f.rb_bind[b]
        pos := jph.RVec3{c.x, c.y, c.z}
        cs := jph.BodyCreationSettings_Create3(cast(^jph.Shape)shape, &pos, &ident, .Kinematic, OBJECT_LAYER_MOVING)
        // limp-but-settling: angular damping bleeds tumble so bodies land
        // extended at their joint stops instead of folding into a ball
        jph.BodyCreationSettings_SetAngularDamping(cs, 2.0)
        jph.BodyCreationSettings_SetLinearDamping(cs, 0.2)
        cg := jph.CollisionGroup{cast(^jph.GroupFilter)self_filter, 0, jph.CollisionSubGroupID(fi * 16 + b)}
        jph.BodyCreationSettings_SetCollisionGroup(cs, &cg)
        f.rb_ids[b] = jph.BodyInterface_CreateAndAddBody(bi, cs, .Activate)
        jph.BodyCreationSettings_Destroy(cs)
    }
    for b in 0 ..< RB_N {
        if RB_PARENT[b] < 0 { continue }
        pb := jph.PhysicsSystem_GetBodyPtr(physics, f.rb_ids[RB_PARENT[b]])
        cb := jph.PhysicsSystem_GetBodyPtr(physics, f.rb_ids[b])
        piv := find_joint(data, RB_PIVOT[b])
        assert(piv >= 0, "rb pivot missing")
        pv := bpos(bindw, piv)
        // twist axis = bone direction (pivot -> child body center at bind)
        tax := f.rb_bind[b] - pv
        if linalg.length(tax) < 1e-6 { tax = [3]f32{0, 1, 0} }
        tax = linalg.normalize(tax)
        up := [3]f32{0, 1, 0}
        xa := [3]f32{1, 0, 0}
        pax := linalg.cross(tax, up)
        if linalg.length(pax) < 1e-3 { pax = linalg.cross(tax, xa) }
        pax = linalg.normalize(pax)
        hip := jph.RVec3{pv.x, pv.y, pv.z}
        taxv := jph.Vec3{tax.x, tax.y, tax.z}
        paxv := jph.Vec3{pax.x, pax.y, pax.z}
        ss: jph.SwingTwistConstraintSettings
        jph.SwingTwistConstraintSettings_Init(&ss)
        ss.space = .WorldSpace
        ss.position1 = hip
        ss.position2 = hip
        ss.twistAxis1 = taxv
        ss.twistAxis2 = taxv
        ss.planeAxis1 = paxv
        ss.planeAxis2 = paxv
        ss.swingType = .Cone
        ss.normalHalfConeAngle = ST_LIM[b][0]
        ss.planeHalfConeAngle = ST_LIM[b][0]
        ss.twistMinAngle = ST_LIM[b][1]
        ss.twistMaxAngle = ST_LIM[b][2]
        joint := jph.SwingTwistConstraint_Create(&ss, pb, cb)
        jph.PhysicsSystem_AddConstraint(physics, cast(^jph.Constraint)joint)
    }
}

// Jolt can NaN a kinematic body on degenerate static contacts (limbs
// grinding a mass edge); a poisoned body then NaNs every read. Scan +
// re-glue from the bumper each step — cheap insurance for the whole game.
body_sanitize :: proc(card: [4]^Fighter, bi: ^jph.BodyInterface, frame: int, auto: bool) {
    for f in card {
        if f.mode != .Anim || !f.do_anim { continue } // dynamic bodies self-integrate
        for b in 0 ..< RB_N {
            pp: jph.RVec3
            jph.BodyInterface_GetPosition(bi, f.rb_ids[b], &pp)
            if pp.x != pp.x || pp.y != pp.y || pp.z != pp.z {
                if auto { fmt.printf("f=%d JOLTNAN %s body=%d\n", frame, f.name, b) }
                lb := [3]f32{f.world[f.rb_node[b]][12], f.world[f.rb_node[b]][13], f.world[f.rb_node[b]][14]}
                wp := yaw_rot(lb, f.yaw) + f.bumper_pos
                wpp := jph.RVec3{wp.x, wp.y, wp.z}
                qk: jph.Quat = 1
                jph.BodyInterface_MoveKinematic(bi, f.rb_ids[b], &wpp, &qk, 1.0 / 60.0)
            }
        }
    }
}

fighter_handoff :: proc(f: ^Fighter, bi: ^jph.BodyInterface, base_vel: [3]f32, kick: bool) {
    fresh := f.mode == .Anim // fresh knockdown restarts the get-up clock; juggles don't
    grab_release(f) // launches drop whatever they held (and escape what held them)
    f.mode = .Ragdoll
    f.dying = false // ragdoll supersedes any death performance
    f.stagger_t = 0 // and any flinch
    f.dodge_t = 0 // launches end dashes
    f.roll_t = 0 // and tumbles
    f.hanging = false // and grips
    f.mm_freeze = f.mm_last
    if fresh { f.handoff_age = 0 }
    f.atk_t = 9999
    for b in 0 ..< RB_N {
        wtb: jph.RMat4
        jph.BodyInterface_GetWorldTransform(bi, f.rb_ids[b], &wtb)
        wbw := transmute([16]f32)wtb
        f.glue_w[b] = {wbw[12], wbw[13], wbw[14]}
        f.rb_off[b] = mul_col(inverse_rigid(wbw), mul_col(f.mm_freeze, f.world[f.rb_node[b]]))
        jph.BodyInterface_SetMotionType(bi, f.rb_ids[b], .Dynamic, .Activate)
        bv := base_vel + (KICK[b] if kick else [3]f32{})
        lv := jph.Vec3{bv.x, bv.y, bv.z}
        jph.BodyInterface_SetLinearVelocity(bi, f.rb_ids[b], &lv)
        avx := f32(1.0) if b % 2 == 0 else f32(-1.0)
        av := jph.Vec3{avx, 0, 0}
        jph.BodyInterface_SetAngularVelocity(bi, f.rb_ids[b], &av)
    }
}

fighter_recover :: proc(f: ^Fighter, bi: ^jph.BodyInterface, to_pos := [3]f32{0, -1, 0}, hf: ^Heightfield = nil) {
    if f.hp <= 0 { return } // the dead stay down; respawn brings them back
    if to_pos.y >= 0 {
        f.bumper_pos = to_pos
    } else {
        pp: jph.RVec3
        jph.BodyInterface_GetPosition(bi, f.rb_ids[0], &pp)
        if pp.x == pp.x && pp.z == pp.z && pp.y == pp.y {
            f.bumper_pos = {pp.x, 0, pp.z}
        } // else: buried body reads NaN — keep bumper, snap below still lands us
    }
    if hf != nil {
        if gy, ok := ground_at(hf, f.bumper_pos.x, f.bumper_pos.z, f.bumper_pos.y); ok {
            f.bumper_pos.y = gy
        }
    }
    f.bumper_vel = {}
    f.vy = 0; f.grounded = true
    f.prev_pos = f.bumper_pos; f.tele_ok = true // legitimate big move
    f.land_t = 0; f.air_t = 0; f.land_elapsed = 0
    f.atk_t = 9999
    f.mode = .Anim
    f.handoff_age = -1
    qp: jph.Quat = 1
    for b in 0 ..< RB_N {
        jph.BodyInterface_SetMotionType(bi, f.rb_ids[b], .Kinematic, .Activate)
        c := f.rb_bind[b]
        kp := jph.RVec3{f.bumper_pos.x + c.x, f.bumper_pos.y + c.y, f.bumper_pos.z + c.z}
        jph.BodyInterface_SetPositionAndRotationWhenChanged(bi, f.rb_ids[b], &kp, &qp, .Activate)
    }
    for i in 0 ..< f.nn {
        f.rec_t[i] = f.data.nodes[i].translation
        f.rec_r[i] = f.data.nodes[i].rotation
    }
    f.rec_blend = 0
}

// fresh challenger: full HP, placed at pos (ground-snapped), cross-fade like a recover
fighter_respawn :: proc(f: ^Fighter, bi: ^jph.BodyInterface, pos: [3]f32, hf: ^Heightfield = nil) {
    f.hp = f.max_hp
    f.prev_hp = f.max_hp
    f.hurt_f = -99999
    f.regen_acc = 0
    grab_release(f) // fresh fighters hold nothing
    for &pr in f.prims { // fresh fighters are whole (stumps heal)
        if pr.sev_node >= 0 {
            pr.sev_node = -1
            if pr.sev_idx != nil { delete(pr.sev_idx); pr.sev_idx = nil }
        }
    }
    if f.carry_idx >= 0 && f.carry_idx < 6 {
        // crate stays where it lies (idle-heal below re-dynamics it)
        if crate_holder[f.carry_idx] == f { crate_holder[f.carry_idx] = nil }
        if crate_state[f.carry_idx] == 1 { crate_state[f.carry_idx] = 0 }
        f.carry_idx = -1
    }
    f.respawn_t = 0
    f.bumper_pos = pos
    if hf != nil {
        if gy, ok := ground_at(hf, pos.x, pos.z, 1e9); ok {
            f.bumper_pos.y = gy
        }
    }
    f.bumper_vel = {}
    f.vy = 0; f.grounded = true
    f.prev_pos = f.bumper_pos; f.tele_ok = true // legitimate big move
    f.land_t = 0; f.air_t = 0; f.land_elapsed = 0
    f.atk_t = 9999
    f.atk_anim = nil; f.atk_kick = false; f.struck = false; f.connected = false
    f.dying = false; f.blocking = false; f.block_t = 0; f.flash_t = 0; f.stagger_t = 0
    f.dodge_t = 0; f.dodge_cd = 0; f.tap_key = 0; f.tap_t = 0
    f.roll_t = 0; f.hanging = false; f.hang_t = 0
    f.has_sword = f.sword_idx >= 0 // fresh challenger re-arms (old steel stays out)
    f.mode = .Anim
    f.handoff_age = -1
    qp: jph.Quat = 1
    for b in 0 ..< RB_N {
        jph.BodyInterface_SetMotionType(bi, f.rb_ids[b], .Kinematic, .Activate)
        c := f.rb_bind[b]
        kp := jph.RVec3{pos.x + c.x, pos.y + c.y, pos.z + c.z}
        jph.BodyInterface_SetPositionAndRotationWhenChanged(bi, f.rb_ids[b], &kp, &qp, .Activate)
    }
    for i in 0 ..< f.nn {
        f.rec_t[i] = f.data.nodes[i].translation
        f.rec_r[i] = f.data.nodes[i].rotation
    }
    f.rec_blend = 0
}

// active ragdoll: weak velocity springs hold the handoff shape
// around the pelvis (targets re-anchored on it every frame)
ragdoll_hold_shape :: proc(f: ^Fighter, bi: ^jph.BodyInterface, dt: f32, pp: jph.RVec3) {
        for b in 1 ..< RB_N {
            if ACT_STR[b] <= 0 { continue }
            bp2: jph.RVec3
            jph.BodyInterface_GetPosition(bi, f.rb_ids[b], &bp2)
            tx := pp.x + (f.glue_w[b].x - f.glue_w[0].x)
            ty := pp.y + (f.glue_w[b].y - f.glue_w[0].y)
            tz := pp.z + (f.glue_w[b].z - f.glue_w[0].z)
            dv := [3]f32{(tx - bp2.x) / dt, (ty - bp2.y) / dt, (tz - bp2.z) / dt}
            dl := linalg.length(dv)
            if dl > 4.0 { dv *= 4.0 / dl }
            cv: jph.Vec3
            jph.BodyInterface_GetLinearVelocity(bi, f.rb_ids[b], &cv)
            k := min(1.0, 8.0 * ACT_STR[b] * dt)
            nv := jph.Vec3{cv.x + (dv.x - cv.x) * k, cv.y + (dv.y - cv.y) * k, cv.z + (dv.z - cv.z) * k}
            jph.BodyInterface_SetLinearVelocity(bi, f.rb_ids[b], &nv)
        }
}
