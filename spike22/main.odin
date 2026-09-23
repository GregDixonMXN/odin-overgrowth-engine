package spike22

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import jph "../thirdparty/joltc-odin"
// spike22 main: setup, loop, camera, HUD, screenshots.
// foe = nearest enemy by team (corpses included: you can juggle the dead)
foe_of :: proc(me: ^Fighter, card: [4]^Fighter) -> ^Fighter {
    best: ^Fighter = nil
    best_d := f32(1e9)
    for i in 0 ..< 4 {
        o := card[i]
        if o == me || o.team == me.team { continue }
        dx := o.bumper_pos.x - me.bumper_pos.x
        dz := o.bumper_pos.z - me.bumper_pos.z
        if d := dx * dx + dz * dz; d < best_d { best_d = d; best = o }
    }
    return best
}

// ---- campaign menus: settings (saved) + full-match reset ----
g_mouse_sens := f32(1.0) // chase-cam multiplier
g_stick_sens := f32(1.0) // right-stick look multiplier
g_master_vol := f32(0.8) // master volume (wind bed + bank)

settings_load :: proc() {
    data, err := os.read_entire_file("campaign.cfg", context.allocator)
    if err != nil { return }
    defer delete(data)
    txt := string(data)
    for line in split_lines_iter(txt) {
        kv := split2(line, "=")
        if len(kv) != 2 { continue }
        v, vok := strconv.parse_f32(kv[1])
        if !vok { continue }
        switch kv[0] {
        case "mouse": g_mouse_sens = clamp01(v)
        case "stick": g_stick_sens = clamp01(v)
        case "deadzone": g_pad_dz = math.clamp(v, 0.02, 0.3)
        case "volume": g_master_vol = clamp01(v)
        }
    }
}

settings_save :: proc() {
    buf := fmt.tprintf("mouse=%.3f\nstick=%.3f\ndeadzone=%.3f\nvolume=%.3f\n",
        g_mouse_sens, g_stick_sens, g_pad_dz, g_master_vol)
    _ = os.write_entire_file("campaign.cfg", transmute([]u8)buf) // best-effort
}

// tiny local parsers (avoid pulling strings for two uses)
split_lines_iter :: proc(s: string) -> []string {
    out := make([dynamic]string)
    start := 0
    for i in 0 ..< len(s) {
        if s[i] == '\n' {
            append(&out, s[start:i])
            start = i + 1
        }
    }
    if start < len(s) { append(&out, s[start:]) }
    return out[:]
}

split2 :: proc(s: string, sep: string) -> []string {
    out := make([dynamic]string)
    for i in 0 ..< len(s) {
        if s[i] == sep[0] {
            append(&out, s[:i])
            append(&out, s[i+1:])
            return out[:]
        }
    }
    append(&out, s)
    return out[:]
}

clamp01 :: proc(v: f32) -> f32 { return math.clamp(v, 0.1, 3.0) }

// full-match reset (was inline in the win banner; now shared by title,
// pause, and rematch so every road starts the same fight)
match_reset :: proc(card: [4]^Fighter, bi: ^jph.BodyInterface, hf: ^Heightfield, frame: int) {
    g_kos_you = 0; g_kos_dummy = 0
    g_firstblood = false; g_matchpoint = false; g_decided = false
    g_severs = 0
    for &d in g_drops { d.active = false } // rematch sweeps the steel
    limbs_clear() // and buries the limbs
    for &dc in g_decals { dc.size = 0 } // and hoses the dirt
    g_decal_next = 0
    for &n in g_noises { n.frame = -99999 } // and goes quiet
    sfx_playi(SFXW_UI)
    sfx_playi(SFXW_START)
    // card order: player, ally, dummy, brute
    fighter_respawn(card[0], bi, {0, 0, 0}, hf)
    fighter_respawn(card[1], bi, {-6, 0, -4}, hf)
    fighter_respawn(card[2], bi, {2, 0, 18}, hf)
    fighter_respawn(card[3], bi, {3, 0, 20}, hf)
    // fresh eyes: hold till sight or sound re-plants info
    for f in card { f.info_pos = f.bumper_pos; f.info_frame = -99999 }
    fmt.printf("f=%d REMATCH\n", frame)
}

Game_State :: enum { Title, Play, Pause }

// title menu: FIGHT + 4 saved settings (Up/Down move, Left/Right tune,
// ENTER fights; pad dpad + A). Drawn over the frozen arena.
title_input :: proc(state: ^Game_State, sel: ^int, card: [4]^Fighter, bi: ^jph.BodyInterface, hf: ^Heightfield, frame: int) {
    if rl.IsKeyPressed(.UP) || pad_menu_up() { sel^ = (sel^ + 4) % 5; sfx_playi(SFXW_UI) }
    if rl.IsKeyPressed(.DOWN) || pad_menu_down() { sel^ = (sel^ + 1) % 5; sfx_playi(SFXW_UI) }
    adj := 0
    if rl.IsKeyPressed(.LEFT) || pad_menu_left() { adj = -1 }
    if rl.IsKeyPressed(.RIGHT) || pad_menu_right() { adj = 1 }
    if adj != 0 && sel^ >= 1 {
        switch sel^ {
        case 1: g_mouse_sens = math.clamp(g_mouse_sens + f32(adj) * 0.1, 0.1, 3.0)
        case 2: g_stick_sens = math.clamp(g_stick_sens + f32(adj) * 0.1, 0.1, 3.0)
        case 3: g_pad_dz = math.clamp(g_pad_dz + f32(adj) * 0.005, 0.02, 0.3)
        case 4:
            g_master_vol = math.clamp(g_master_vol + f32(adj) * 0.1, 0.0, 1.0)
            rl.SetMasterVolume(g_master_vol)
        }
        settings_save()
    }
    if (rl.IsKeyPressed(.ENTER) || pad_menu_confirm()) && sel^ == 0 {
        match_reset(card, bi, hf, frame)
        state^ = .Play
    }
}

title_draw :: proc(sel: int) {
    rl.DrawText("APOCALYPSE INSURANCE", 300, 160, 64, rl.RAYWHITE)
    rl.DrawText("2v2 ARENA - FIRST TO FIVE TAKES IT", 430, 230, 24, rl.ORANGE)
    rows := [5]cstring{
        "FIGHT",
        rl.TextFormat("MOUSE SENS   %.1f", g_mouse_sens),
        rl.TextFormat("STICK SENS   %.1f", g_stick_sens),
        rl.TextFormat("PAD DEADZONE %.3f", f64(g_pad_dz)),
        rl.TextFormat("VOLUME       %.1f", g_master_vol),
    }
    for r, i in rows {
        c := rl.YELLOW if i == sel else rl.RAYWHITE
        rl.DrawText(r, 480, i32(300 + i * 40), 28, c)
    }
    rl.DrawText("UP/DOWN move  LEFT/RIGHT tune  ENTER fight  (pad: dpad + A)", 330, 540, 20, rl.GRAY)
}

// pause menu: resume / rematch / quit (ESC resumes; pad Start/B resume)
pause_input :: proc(state: ^Game_State, sel: ^int, card: [4]^Fighter, bi: ^jph.BodyInterface, hf: ^Heightfield, frame: int) {
    if rl.IsKeyPressed(.UP) || pad_menu_up() { sel^ = (sel^ + 2) % 3; sfx_playi(SFXW_UI) }
    if rl.IsKeyPressed(.DOWN) || pad_menu_down() { sel^ = (sel^ + 1) % 3; sfx_playi(SFXW_UI) }
    if rl.IsKeyPressed(.ENTER) || pad_menu_confirm() {
        switch sel^ {
        case 0: state^ = .Play
        case 1:
            match_reset(card, bi, hf, frame)
            state^ = .Play
        case 2:
            match_reset(card, bi, hf, frame)
            state^ = .Title
        }
    }
}

pause_draw :: proc(sel: int) {
    rl.DrawText("PAUSED", 560, 200, 60, rl.RAYWHITE)
    rows := [3]cstring{"RESUME", "REMATCH", "QUIT TO TITLE"}
    for r, i in rows {
        c := rl.YELLOW if i == sel else rl.RAYWHITE
        rl.DrawText(r, 540, i32(300 + i * 44), 32, c)
    }
    rl.DrawText("UP/DOWN move  ENTER choose  ESC resume", 440, 470, 20, rl.GRAY)
}

main :: proc() {
    auto := len(os.args) > 1 && (os.args[1] == "auto" || os.args[1] == "autoai")
    // autoai: scripted player + deterministic screenshots AND live brains —
    // the AI-limits harness (plain auto holds enemies still for baselines)
    brains := (len(os.args) > 1 && os.args[1] == "autoai") || !auto
    do_shot := (len(os.args) > 2 && os.args[2] == "shot") || (len(os.args) > 3 && os.args[3] == "shot")
    dt := f32(1.0 / 60.0)

    sh := load_shared_anims()

    rl.InitWindow(1280, 720, "spike21 - cancel windows")

    rl.SetTargetFPS(60)
    if !auto { rl.DisableCursor() } // captured mouse-look (OG-style); auto demo untouched
    g_sfx = sfx_init()
    settings_load() // campaign.cfg beside the exe (missing = defaults)
    rl.SetMasterVolume(g_master_vol)
    rl.SetExitKey(.KEY_NULL) // ESC opens the pause menu, not the window

    player := make_fighter("../assets/shki_base.glb", {255, 255, 255, 255}, 1.0, "../assets/shki_albedo.png")
    player.is_player = true
    player.team = 0
    player.name = "player"
    player.max_hp = 5
    player.hp = 5
    player.atk_rate = 1.5 // player swings faster (enemies stay readable)
    g_shki_bind_t = player.base_t // retarget reference for cross-rig fighters
    g_shki_bind_n = player.nn
    // LUNK BRUTE: same rig at 0.12 scale (~3m), slower, hits for 2, kick-only AI
    dummy := make_fighter("../assets/lunk_base.glb", {255, 130, 130, 255}, 0.12, "../assets/lunk_albedo.png", "../assets/lunk_normal.png")
    dummy.is_player = false
    dummy.team = 1
    dummy.name = "dummy"
    dummy.accel_rate = 9.0
    dummy.top_speed = 4.5
    dummy.max_hp = 8
    dummy.dmg = 2
    dummy.kicks = true
    dummy.bumper_pos = {2, 0, 18} // brute holds the alley
    dummy.ai_aggr = 0.75 // brute: presses in, kicks, rarely backs off
    dummy.ai_range = 2.0
    dummy.ai_dir = 1.0
    // auto demo: 1-HP dummies so every proximity slash is a K.O.
    // (autoai keeps manual HP — brains need real fights, not flee loops)
    dummy.hp = 1 if (auto && !brains) else 8
    // CUTTHROAT: fast shki slasher, blue. Second hunter in the 2v1.
    cut := make_fighter("../assets/shki_base.glb", {150, 180, 255, 255}, 1.0, "../assets/shki_albedo.png")
    cut.is_player = false
    cut.team = 1
    cut.name = "cut"
    cut.accel_rate = 14.0
    cut.top_speed = 7.0
    cut.max_hp = 5
    cut.dmg = 1
    cut.bumper_pos = {3, 0, 24} // cutthroat perches the tower (snaps to top)
    cut.hp = 1 if (auto && !brains) else 5
    cut.ai_aggr = 0.5 // cutthroat: circles, darts in, gives ground
    cut.ai_range = 2.8 // sword reach (was 2.3 fists)
    cut.ai_dir = -1.0
    // ALLY: green shki slasher on your side. Escorts you (regroups past
    // 6m), fights your nearest foe, sidesteps like the cut (aggr 0.6).
    // Spawned off the scripted demo path so auto stays clean.
    ally := make_fighter("../assets/shki_base.glb", {140, 220, 150, 255}, 1.0, "../assets/shki_albedo.png")
    ally.is_player = false
    ally.team = 0
    ally.name = "ally"
    ally.accel_rate = 12.0
    ally.top_speed = 6.0
    ally.max_hp = 5
    ally.dmg = 1
    ally.bumper_pos = {-6, 0, -4} // off-path: scripted demo never goes here
    ally.hp = 1 if (auto && !brains) else 5
    ally.ai_aggr = 0.6 // darter: circles, sidesteps, gives ground
    ally.ai_range = 2.8
    ally.ai_dir = 1.0
    // TEMP ally bisect: construction only (no sword/bodies/update/render)
    fmt.printf("player prims %d, dummy prims %d, cut prims %d, ally prims %d\n", len(player.prims), len(dummy.prims), len(cut.prims), len(ally.prims))
    // swords for the slashers (brute keeps fists + kicks)
    fighter_give_sword(&player, "../assets/sword_albedo.png", "../assets/sword_normal.png")
    fighter_give_sword(&cut, "../assets/sword_albedo.png", "../assets/sword_normal.png")
    fighter_give_sword(&ally, "../assets/sword_albedo.png", "../assets/sword_normal.png")

    // ---- physics ----
    assert(jph.Init())
    defer jph.Shutdown()
    jobs := jph.JobSystemThreadPool_Create(nil)
    defer jph.JobSystem_Destroy(jobs)
    pair_filter := jph.ObjectLayerPairFilterTable_Create(2)
    jph.ObjectLayerPairFilterTable_EnableCollision(pair_filter, OBJECT_LAYER_MOVING, OBJECT_LAYER_MOVING)
    jph.ObjectLayerPairFilterTable_EnableCollision(pair_filter, OBJECT_LAYER_MOVING, OBJECT_LAYER_NON_MOVING)
    bp_table := jph.BroadPhaseLayerInterfaceTable_Create(2, 2)
    jph.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(bp_table, OBJECT_LAYER_NON_MOVING, 0)
    jph.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(bp_table, OBJECT_LAYER_MOVING, 1)
    bp_filter := jph.ObjectVsBroadPhaseLayerFilterTable_Create(bp_table, 2, pair_filter, 2)
    settings := jph.PhysicsSystemSettings{
        maxBodies                     = 1024,
        maxBodyPairs                  = 1024,
        maxContactConstraints         = 1024,
        broadPhaseLayerInterface      = bp_table,
        objectLayerPairFilter         = pair_filter,
        objectVsBroadPhaseLayerFilter = bp_filter,
    }
    physics := jph.PhysicsSystem_Create(&settings)
    defer jph.PhysicsSystem_Destroy(physics)
    bi := jph.PhysicsSystem_GetBodyInterface(physics)
    ident : jph.Quat = 1
    self_filter := jph.GroupFilterTable_Create(64) // 4 fighters x 16 subgroups
    terr := load_terrain("../assets/landscape.glb", bi)
    arena := load_arena(bi, &terr.hf)
    g_arena = &arena
    player.bumper_pos.y, _ = ground_at(&terr.hf, player.bumper_pos.x, player.bumper_pos.z, 1e9)
    dummy.bumper_pos.y, _ = ground_at(&terr.hf, dummy.bumper_pos.x, dummy.bumper_pos.z, 1e9)
    cut.bumper_pos.y, _ = ground_at(&terr.hf, cut.bumper_pos.x, cut.bumper_pos.z, 1e9)
    ally.bumper_pos.y, _ = ground_at(&terr.hf, ally.bumper_pos.x, ally.bumper_pos.z, 1e9)
    fmt.printf("spawn you=(%.1f %.1f) dummy=(%.1f %.1f) cut=(%.1f %.1f) ally=(%.1f %.1f)\n", player.bumper_pos.x, player.bumper_pos.y, dummy.bumper_pos.x, dummy.bumper_pos.y, cut.bumper_pos.x, cut.bumper_pos.y, ally.bumper_pos.x, ally.bumper_pos.y)
    // perception starts sighted (open ground at spawn)
    dummy.info_pos = player.bumper_pos
    cut.info_pos = player.bumper_pos
    ally.info_pos = dummy.bumper_pos
    make_ragdoll(&player, bi, physics, self_filter, 0)
    make_ragdoll(&dummy, bi, physics, self_filter, 1)
    make_ragdoll(&cut, bi, physics, self_filter, 2)
    make_ragdoll(&ally, bi, physics, self_filter, 3)
    // no self-collision within each fighter (separate subgroup ranges)
    for b in 0 ..< RB_N {
        for c in 0 ..< RB_N {
            jph.GroupFilterTable_DisableCollision(self_filter, jph.CollisionSubGroupID(0 * 16 + b), jph.CollisionSubGroupID(0 * 16 + c))
            jph.GroupFilterTable_DisableCollision(self_filter, jph.CollisionSubGroupID(1 * 16 + b), jph.CollisionSubGroupID(1 * 16 + c))
            jph.GroupFilterTable_DisableCollision(self_filter, jph.CollisionSubGroupID(2 * 16 + b), jph.CollisionSubGroupID(2 * 16 + c))
            jph.GroupFilterTable_DisableCollision(self_filter, jph.CollisionSubGroupID(3 * 16 + b), jph.CollisionSubGroupID(3 * 16 + c))
        }
    }
    crate_ids: [6]jph.BodyID
    for zi in 0 ..< 2 {
        for xi in 0 ..< 3 {
            he := jph.Vec3{0.4, 0.4, 0.4}
            shape := jph.BoxShapeSettings_CreateShape(jph.BoxShapeSettings_Create(&he, 0.05))
            gx := f32(xi) * 1.0 - 1.0
            gy, _ := ground_at(&terr.hf, gx, 12.5, 1e9)
            pos := jph.RVec3{gx, gy + 0.4 + f32(zi) * 0.85, 12.5}
            cs := jph.BodyCreationSettings_Create3(cast(^jph.Shape)shape, &pos, &ident, .Dynamic, OBJECT_LAYER_MOVING)
            crate_ids[zi * 3 + xi] = jph.BodyInterface_CreateAndAddBody(bi, cs, .Activate)
            jph.BodyCreationSettings_Destroy(cs)
        }
    }
    jph.PhysicsSystem_OptimizeBroadPhase(physics)

    cube_mesh := rl.GenMeshCube(0.8, 0.8, 0.8)
    rl.UploadMesh(&cube_mesh, false)
    cube_mat := rl.LoadMaterialDefault()
    cube_mat.maps[0].color = rl.BROWN

    // sky dome: vertical gradient baked into vertex colors (no sky/fog
    // API in the bindings). Follows the view target so you never reach it.
    sky := rl.GenMeshSphere(400, 16, 32)
    {
        n := int(sky.vertexCount)
        cols := make([]u8, n * 4)
        for i in 0 ..< n {
            t := sky.vertices[i*3+1] / 400.0
            c: [3]f32
            if t >= 0 {
                k := math.pow(t, 0.6)
                c = {215, 195, 170} * (1 - k) + {35, 80, 170} * k
            } else {
                k := math.min(-t * 3.0, 1.0)
                c = {215, 195, 170} * (1 - k) + {55, 48, 38} * k
            }
            cols[i*4] = u8(math.clamp(c.x, 0, 255))
            cols[i*4+1] = u8(math.clamp(c.y, 0, 255))
            cols[i*4+2] = u8(math.clamp(c.z, 0, 255))
            cols[i*4+3] = 255
        }
        sky.colors = raw_data(cols)
        rl.UploadMesh(&sky, false)
    }
    sky_mat := rl.LoadMaterialDefault()
    sky_mat.maps[0].color = rl.WHITE
    // unlit gradient: the bundled DLL predates the binding's Mesh layout
    // (no texcoords2), so the colors pointer lands wrong — drive the
    // gradient from local height instead (sphere UVs pinch at the poles).
    // Dithered to kill color banding.
    sky_vs :: "#version 330\nin vec3 vertexPosition; out float gy; uniform mat4 mvp; void main() { gy = vertexPosition.y / 400.0; gl_Position = mvp*vec4(vertexPosition, 1.0); }"
    sky_fs :: "#version 330\nin float gy; out vec4 finalColor; void main() { vec3 zen = vec3(0.14, 0.31, 0.67); vec3 hor = vec3(0.84, 0.76, 0.66); vec3 gnd = vec3(0.22, 0.19, 0.15); float h = clamp(gy, -1.0, 1.0); vec3 c = h > 0.0 ? mix(hor, zen, pow(h, 0.6)) : mix(hor, gnd, min(-h*3.0, 1.0)); float n = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453); c += (n - 0.5) * 0.012; finalColor = vec4(c, 1.0); }"
    sky_mat.shader = rl.LoadShaderFromMemory(sky_vs, sky_fs)

    cam := rl.Camera3D{
        position = {0, 3.2, -6}, target = {0, 1.2, 0}, up = {0, 1, 0},
        fovy = 55, projection = .PERSPECTIVE,
    }
    // OG-style chase cam state (manual play only; auto keeps the old rails):
    // mouse drives target yaw/pitch, inertia smooths, assist trails behind
    // the player and frames the nearest foe (side view close, straight far).
    cam_rot, cam_rot2 := player.yaw + math.PI, f32(-0.20)
    tgt_rot, tgt_rot2 := cam_rot, cam_rot2
    cam_override := f32(0)   // recent manual look suppresses assist
    cam_side_w := f32(0)     // which side of the foe we frame (0/1 latch)
    cam_tgt_w := f32(0)      // target-framing weight
    cam_anchor := [3]f32{}   // smoothed anchor (position inertia)
    cam_anchor_set := false
    CAM_DIST :: f32(4.5)
    ctx := Ctx{sh = &sh, bi = bi, crate_ids = crate_ids, hf = &terr.hf, dt = dt, frame = 0, auto = auto, brains = brains}
    menu_card := [4]^Fighter{&player, &ally, &dummy, &cut} // title/pause resets use the same card

    frame := 0
    state := Game_State.Play if auto else Game_State.Title // headless skips the menus
    title_sel := 0 // 0 fight, 1 mouse, 2 stick, 3 deadzone, 4 volume
    pause_sel := 0 // 0 resume, 1 rematch, 2 quit to title
    for !rl.WindowShouldClose() {
        ctx.frame = frame
        running := state == .Play
        if frame == 0 && running { bark_say(&ctx, "horn", "FIRST TO FIVE TAKES IT"); sfx_playi(SFXW_START) }
        pad_read() // pad 0 into g_pad (no pad = all-false, run stays clean)
        // menus: ESC/Start pauses a live match, ESC/B resumes, title owns its keys
        if state == .Play && !match_over() && (rl.IsKeyPressed(.ESCAPE) || pad_rematch()) { state = .Pause; pause_sel = 0 }
        else if state == .Pause && (rl.IsKeyPressed(.ESCAPE) || pad_menu_back()) { state = .Play }
        if state == .Title { title_input(&state, &title_sel, menu_card, bi, &terr.hf, frame) }
        else if state == .Pause { pause_input(&state, &pause_sel, menu_card, bi, &terr.hf, frame) }
        if ctx.hitstop_f > 0 {
            // impact freeze: world holds its breath (render + camera still run)
            ctx.hitstop_f -= 1
        } else if running {
        // foe = nearest living enemy by team (2v2: allies escort you,
        // hunters pick the closest of your side)
        card := [4]^Fighter{&player, &ally, &dummy, &cut}
        ctx.ally_anchor = player.bumper_pos // escort post follows you
        pfoe := foe_of(&player, card)
        if pfoe == nil { pfoe = &dummy } // card decided: hold last foe
        fighter_update(&player, pfoe, &ctx, &cam)
        dfoe := foe_of(&dummy, card)
        if dfoe == nil { dfoe = &player }
        fighter_update(&dummy, dfoe, &ctx, &cam)
        cfoe := foe_of(&cut, card)
        if cfoe == nil { cfoe = &player }
        fighter_update(&cut, cfoe, &ctx, &cam)
        afoe := foe_of(&ally, card)
        if afoe == nil { afoe = &dummy }
        fighter_update(&ally, afoe, &ctx, &cam)
        // separation: nobody stacks (all pairs, both Anim; the player
        // keeps the old solo path, so the demo rails never drift)
        for i in 0 ..< 4 {
            for j in i + 1 ..< 4 {
                a := card[i]; b := card[j]
                if a.mode != .Anim || b.mode != .Anim { continue }
                if a.is_player || b.is_player { continue }
                sx := a.bumper_pos.x - b.bumper_pos.x
                sz := a.bumper_pos.z - b.bumper_pos.z
                sd := math.sqrt(sx * sx + sz * sz)
                if sd < 1.5 && sd > 1e-4 {
                    push := (1.5 - sd) * 0.5 / sd
                    a.bumper_pos.x += sx * push
                    a.bumper_pos.z += sz * push
                    b.bumper_pos.x -= sx * push
                    b.bumper_pos.z -= sz * push
                }
            }
        }
        jph.PhysicsSystem_Update(physics, dt, 1, jobs)
        body_sanitize(card, bi, frame, auto) // re-glue any NaNed bodies
        parts_update(&g_parts, dt)
        crates_update(&ctx, card) // carried ride, hurled wound
        drops_update_thrown(&ctx, card)
        ragdoll_impacts(&ctx, card) // fast bodies bowl pins
        limbs_update(&ctx) // severed pieces fly and settle
        } // end else (hitstop): sim advances

        // camera: anchor on player (pelvis when ragdolled), smoothed
        anc := player.bumper_pos
        if player.mode == .Ragdoll {
            rap: jph.RVec3
            jph.BodyInterface_GetPosition(bi, player.rb_ids[0], &rap)
            anc = {rap.x, rap.y, rap.z}
        }
        anc_ty := max(anc.y, 0.4) + 1.2
        tgt := [3]f32{anc.x, anc_ty, anc.z}
        if !cam_anchor_set { cam_anchor = tgt; cam_anchor_set = true }
        cam_anchor += (tgt - cam_anchor) * (1.0 - math.exp(-10.0 * dt))
        want: [3]f32
        if auto {
            // demo rails (baseline-stable): yaw-behind dolly
            back := [3]f32{-math.sin(player.yaw), 0, -math.cos(player.yaw)} * 3.2
            want = [3]f32{anc.x + back.x, anc_ty + 2.0, anc.z + back.z}
            tgt = [3]f32{anc.x, anc_ty, anc.z}
        } else {
            // OG chase cam (ApplyCameraControls): mouse steers target
            // yaw/pitch, inertia smooths, assist trails + frames the foe.
            mdx := rl.GetMouseDelta()
            if mdx.x != 0 || mdx.y != 0 {
                tgt_rot -= mdx.x * 0.0035 * g_mouse_sens
                tgt_rot2 -= mdx.y * 0.0030 * g_mouse_sens
                cam_override = min(2.5, cam_override + (math.abs(mdx.x) + math.abs(mdx.y)) * 0.005)
            }
            if g_pad.look.x != 0 || g_pad.look.y != 0 { // right stick looks
                tgt_rot -= g_pad.look.x * 2.5 * g_stick_sens * dt
                tgt_rot2 += g_pad.look.y * 1.8 * g_stick_sens * dt
                cam_override = min(2.5, cam_override + (math.abs(g_pad.look.x) + math.abs(g_pad.look.y)) * 0.6 * dt)
            }
            cam_override *= math.exp(-0.6 * dt)
            tgt_rot2 = math.clamp(tgt_rot2, -1.4, 0.7)
            if cam_override < 1.0 {
                // trail: drift behind the player's heading when moving
                if player.speed > 1.0 {
                    want_rot := player.yaw + math.PI
                    for want_rot < cam_rot - math.PI { want_rot += 2 * math.PI }
                    for want_rot > cam_rot + math.PI { want_rot -= 2 * math.PI }
                    tgt_rot += (want_rot - tgt_rot) * (1.0 - math.exp(-3.0 * dt))
                }
                // frame the nearest foe: side view close, straight far
                cam_foe := &dummy
                cdx := cut.bumper_pos.x - player.bumper_pos.x
                cdz := cut.bumper_pos.z - player.bumper_pos.z
                ddx2 := dummy.bumper_pos.x - player.bumper_pos.x
                ddz2 := dummy.bumper_pos.z - player.bumper_pos.z
                if cdx * cdx + cdz * cdz < ddx2 * ddx2 + ddz2 * ddz2 { cam_foe = &cut }
                fdx := cam_foe.bumper_pos.x - player.bumper_pos.x
                fdz := cam_foe.bumper_pos.z - player.bumper_pos.z
                fdist := math.sqrt(fdx * fdx + fdz * fdz)
                if cam_foe.hp > 0 && fdist < 12.0 && fdist > 1e-4 {
                    tx, tz := fdx / fdist, fdz / fdist
                    ang := max(0.2, 1.2 / max(1.0, fdist))
                    ca, sa := math.cos(ang), math.sin(ang)
                    // candidate side views (rotate target dir ±ang)
                    rx, rz := tx * ca + tz * sa, -tx * sa + tz * ca
                    lx, lz := tx * ca - tz * sa, tx * sa + tz * ca
                    fx := -math.sin(cam_rot); fz := -math.cos(cam_rot)
                    if lx * fx + lz * fz > rx * fx + rz * fz {
                        cam_side_w += (0.0 - cam_side_w) * (1.0 - math.exp(-3.0 * dt))
                    } else {
                        cam_side_w += (1.0 - cam_side_w) * (1.0 - math.exp(-3.0 * dt))
                    }
                    sx := lx + (rx - lx) * cam_side_w
                    sz := lz + (rz - lz) * cam_side_w
                    w_raw := math.clamp(3.0 / fdist, 0.0, 1.0)
                    if w_raw <= 0.3 { w_raw = 0.0 }
                    cam_tgt_w += (w_raw - cam_tgt_w) * (1.0 - math.exp(-2.0 * dt))
                    bx := fx + (sx - fx) * cam_tgt_w
                    bz := fz + (sz - fz) * cam_tgt_w
                    if bx * bx + bz * bz > 0.01 {
                        des := math.atan2(-bx, -bz)
                        for des < cam_rot - math.PI { des += 2 * math.PI }
                        for des > cam_rot + math.PI { des -= 2 * math.PI }
                        tgt_rot = des
                    }
                } else {
                    cam_tgt_w *= math.exp(-2.0 * dt)
                }
                // pitch relaxes toward a slight look-down
                tgt_rot2 += (-0.20 - tgt_rot2) * (1.0 - math.exp(-1.5 * dt))
            }
            // rotation inertia (kCameraRotationInertia)
            for tgt_rot < cam_rot - math.PI { tgt_rot += 2 * math.PI }
            for tgt_rot > cam_rot + math.PI { tgt_rot -= 2 * math.PI }
            kk := 1.0 - math.exp(-8.0 * dt)
            cam_rot += (tgt_rot - cam_rot) * kk
            cam_rot2 += (tgt_rot2 - cam_rot2) * kk
            // facing = R_y(rot) * R_x(rot2) * (0,0,-1); dolly sits behind it
            cp, sp := math.cos(cam_rot2), math.sin(cam_rot2)
            facing := [3]f32{-math.sin(cam_rot) * cp, sp, -math.cos(cam_rot) * cp}
            tgt = cam_anchor
            want = cam_anchor - facing * CAM_DIST
        }
        // camera-terrain collision: walk out from the target, stop before buried
        placed := want
        for s in 1 ..= 20 {
            k := f32(s) / 20.0
            px := tgt.x + (want.x - tgt.x) * k
            py := tgt.y + (want.y - tgt.y) * k
            pz := tgt.z + (want.z - tgt.z) * k
            blocked := false
            if gy, ok := height_at(&terr.hf, px, pz); ok {
                if py < gy + 0.5 { blocked = true }
            }
            if !blocked {
                // camera-crate collision: 6 crates as spheres (dynamic)
                for ci in 0 ..< 6 {
                    cp: jph.RVec3
                    jph.BodyInterface_GetPosition(bi, crate_ids[ci], &cp)
                    dx, dy, dz := px - cp.x, py - cp.y, pz - cp.z
                    if dx * dx + dy * dy + dz * dz < 0.85 * 0.85 { blocked = true; break }
                }
                // camera-building collision: pull in before the mass
                if arena_point_blocked({px, py, pz}) { blocked = true }
            }
            if blocked {
                // farthest clear wins; target buried -> ride the anchor (k=0)
                // instead of sitting inside the mass
                kk := f32(s - 1) / 20.0
                placed = {tgt.x + (want.x - tgt.x) * kk, tgt.y + (want.y - tgt.y) * kk, tgt.z + (want.z - tgt.z) * kk}
                break
            }
            placed = {px, py, pz}
        }
        cam.position = placed
        cam.target = tgt
        // up close the lens sits inside the skull: hide our own mesh
        // (OG does the same) instead of filling the screen with backfaces
        dx := placed.x - tgt.x; dy := placed.y - tgt.y; dz := placed.z - tgt.z
        ctx.hide_player = dx * dx + dy * dy + dz * dz < 1.44
        // screenshake: deterministic jitter, decays fast
        if ctx.shake > 0.001 {
            sfx := math.sin(f32(frame) * 39.7) * ctx.shake * 0.35
            sfy := math.sin(f32(frame) * 27.3 + 1.7) * ctx.shake * 0.25
            cam.position.x += sfx
            cam.position.y += sfy
            ctx.shake *= math.exp(-8.0 * dt)
        }

        rl.BeginDrawing()
        rl.ClearBackground({200, 185, 160, 255})
        if g_music_ok { rl.UpdateMusicStream(g_music) } // wind bed
        rl.BeginMode3D(cam)
        // sky first (depth handles the rest); dome rides the view target
        skym: [16]f32 = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tgt.x, tgt.y, tgt.z, 1}
        // blending is on globally by default: kill it for opaque 3D or the
        // bright clear color washes everything out (old dark clear hid it)
        rlgl.DisableColorBlend()
        rlgl.DisableBackfaceCulling()
        rl.DrawMesh(sky, sky_mat, to_rl(skym))
        rlgl.EnableBackfaceCulling()
        rl.DrawMesh(terr.mesh, terr.mat, to_rl(IDENT16))
        _ = terr
        arena_render(&arena)
        for ci in 0 ..< 6 {
            cwt: jph.RMat4
            jph.BodyInterface_GetWorldTransform(bi, crate_ids[ci], &cwt)
            rl.DrawMesh(cube_mesh, cube_mat, to_rl(transmute([16]f32)cwt))
        }
        if !ctx.hide_player { render_fighter(&player) }
        render_fighter(&dummy)
        render_fighter(&cut)
        render_fighter(&ally)
        drops_render()
        limbs_render() // severed pieces lie where they fell
        decals_render()
        parts_render(&g_parts)
        rl.EndMode3D()
        rlgl.EnableColorBlend() // HUD text needs alpha blending
        if state == .Title {
            title_draw(title_sel)
        } else if state == .Pause {
            rl.DrawRectangle(0, 0, 1280, 720, {0, 0, 0, 140})
            pause_draw(pause_sel)
        } else {
        rl.DrawText(rl.TextFormat("you HP %d  ally HP %d  brute HP %d  cut HP %d  KOs you %d - %d foe  (first to %d)", player.hp, ally.hp, dummy.hp, cut.hp, g_kos_you, g_kos_dummy, WIN_SCORE), 12, 12, 20, rl.RAYWHITE)
        barks_tick(ctx.dt)
        if !g_matchpoint && (g_kos_you == WIN_SCORE - 1 || g_kos_dummy == WIN_SCORE - 1) {
            g_matchpoint = true
            bark_say(&ctx, "horn", "MATCH POINT")
        }
        if match_over() {
            // match decided: banner + rematch (ENTER resets the whole card)
            won := g_kos_you >= WIN_SCORE
            if !g_decided { g_decided = true; bark_say(&ctx, "horn", "YOU TAKE IT" if won else "YOU FALL"); sfx_playi(SFXW_WIN if won else SFXW_LOSE) }
            rl.DrawText("YOU WIN" if won else "YOU LOSE", 540, 280, 60, rl.GREEN if won else rl.RED)
            mins := frame / 3600; secs := (frame / 60) % 60
            rl.DrawText(rl.TextFormat("TIME %d:%02d   SEVERED %d", mins, secs, g_severs), 540, 348, 24, rl.GRAY)
            rl.DrawText("ENTER rematch   T title", 540, 378, 24, rl.RAYWHITE)
            if rl.IsKeyPressed(.ENTER) || pad_rematch() {
                match_reset([4]^Fighter{&player, &ally, &dummy, &cut}, bi, &terr.hf, frame)
            }
            if rl.IsKeyPressed(.T) {
                match_reset([4]^Fighter{&player, &ally, &dummy, &cut}, bi, &terr.hf, frame)
                state = .Title; title_sel = 0
            }
        } else if player.hp <= 0 || dummy.hp <= 0 || cut.hp <= 0 || ally.hp <= 0 {
            rl.DrawText("K.O.!", 590, 300, 40, rl.RED)
        }
        bi := i32(0)
        for b in g_barks {
            if b.t > 0 {
                rl.DrawText(rl.TextFormat("%s: %s", b.who, b.text), 500, 600 + bi * 26, 24, rl.ORANGE if b.who == "horn" else rl.RAYWHITE)
                bi += 1
            }
        }
        rl.DrawText("WASD move 2x-tap dodge SPACE jump/vault C sneak R ragdoll T recover J slash K kick G throw F grab Shift block E pickup/lift", 12, 38, 20, rl.GRAY)
        if g_pad.active {
            rl.DrawText("pad: sticks move/look RT slash LT kick A jump RB dodge LB guard L3 sneak X pickup/lift Up throw Down grab Y ragdoll B recover Start rematch", 12, 114, 20, rl.GREEN)
        }
        if player.hanging {
            rl.DrawText("ledge: SPACE up / S drop / A D shimmy", 12, 90, 20, rl.YELLOW)
        }
        rl.DrawFPS(12, 64)
        } // end Play HUD (title/pause draw their own above)
        rl.EndDrawing()

        if auto && frame % 120 == 0 {
            dgy, _ := ground_at(&terr.hf, dummy.bumper_pos.x, dummy.bumper_pos.z, dummy.bumper_pos.y)
            cgy, _ := ground_at(&terr.hf, cut.bumper_pos.x, cut.bumper_pos.z, cut.bumper_pos.y)
            fmt.printf("f=%d you=%s dummy=%s pos=(%.2f %.2f %.2f) cam=(%.1f %.1f %.1f)\n", frame, player.state, dummy.state, player.bumper_pos.x, player.bumper_pos.y, player.bumper_pos.z, cam.position.x, cam.position.y, cam.position.z)
            fmt.printf("   dummy bumper=(%.2f %.2f %.2f) ground=%.2f mode=%v\n", dummy.bumper_pos.x, dummy.bumper_pos.y, dummy.bumper_pos.z, dgy, dummy.mode)
            fmt.printf("   cut bumper=(%.2f %.2f %.2f) ground=%.2f mode=%v\n", cut.bumper_pos.x, cut.bumper_pos.y, cut.bumper_pos.z, cgy, cut.mode)
        }
        if auto && do_shot && frame == 10 { rl.TakeScreenshot("shot22_spawn.png") }
        if auto && do_shot && frame == 200 { rl.TakeScreenshot("shot22_sprawl.png") }
        if auto && do_shot && frame == 165 { rl.TakeScreenshot("shot22_hit.png") }
        if auto && do_shot && frame == 250 { rl.TakeScreenshot("shot22_ko.png") }
        if auto && do_shot && frame == 315 { rl.TakeScreenshot("shot22_kick.png") }
        if auto && do_shot && frame == 500 { rl.TakeScreenshot("shot22_hill.png") }
        if running { frame += 1 } // menus hold the frame (fight resumes clean)
        if auto && frame >= 900 { break }
    }
    fmt.printf("spike22 done: %d frames KOs you %d - %d foe\n", frame, g_kos_you, g_kos_dummy)
    rl.CloseWindow()
}
