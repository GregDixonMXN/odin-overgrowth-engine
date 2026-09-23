package spike22

import "core:fmt"
import rl "vendor:raylib"
// spike22 sfx: real-file sound bank (Desktop/sounds stock, staged under
// assets/sfx) + wind bed + stride footsteps. Silent-safe: every slot has
// an ok flag, and the whole bank no-ops with no audio device.

SFXW_WHOOSH :: 0 // Combat/swipe
SFXW_HIT    :: 1 // Weapons/sword_slice
SFXW_THUD   :: 2 // Combat/kick
SFXW_BLOCK  :: 3 // Weapons/sword_clash
SFXW_KO     :: 4 // Combat/crunch_splat
SFXW_VAULT  :: 5 // Environment/air_burst
SFXW_STEP0  :: 6 // Footsteps/gravel 1-4 (stride cycle)
SFXW_STEP1  :: 7
SFXW_STEP2  :: 8
SFXW_STEP3  :: 9
SFXW_UI     :: 10 // UI/sci_fi_confirm (rematch)
SFXW_START  :: 11 // music_box_level_start (match start)
SFXW_WIN    :: 12 // music_box_level_complete (victory)
SFXW_LOSE   :: 13 // music_box_defeated (defeat)
SFXW_STING  :: 14 // horror_sting (first blood)
SFX_N :: 15

SFX :: struct {
    bank:  [SFX_N]rl.Sound,
    ok:    [SFX_N]bool,
    ready: bool,
}

g_sfx: SFX
g_music: rl.Music
g_music_ok: bool

sfx_load :: proc(s: ^SFX, idx: int, path: string, vol: f32) {
    snd := rl.LoadSound(cstring(raw_data(path)))
    if rl.IsSoundValid(snd) {
        s.bank[idx] = snd
        s.ok[idx] = true
        rl.SetSoundVolume(snd, vol)
    } else {
        fmt.printf("sfx: missing %s\n", path)
    }
}

sfx_init :: proc() -> SFX {
    s: SFX
    rl.InitAudioDevice()
    s.ready = rl.IsAudioDeviceReady()
    if !s.ready {
        fmt.printf("sfx: no audio device, silent\n")
        return s
    }
    A :: "../assets/sfx/"
    sfx_load(&s, SFXW_WHOOSH, A + "swipe.wav", 0.35)
    sfx_load(&s, SFXW_HIT, A + "sword_slice.wav", 0.5)
    sfx_load(&s, SFXW_THUD, A + "kick.wav", 0.6)
    sfx_load(&s, SFXW_BLOCK, A + "sword_clash.wav", 0.45)
    sfx_load(&s, SFXW_KO, A + "crunch_splat.wav", 0.7)
    sfx_load(&s, SFXW_VAULT, A + "air_burst.wav", 0.3)
    sfx_load(&s, SFXW_STEP0, A + "foley_footstep_gravel_1.wav", 0.3)
    sfx_load(&s, SFXW_STEP1, A + "foley_footstep_gravel_2.wav", 0.3)
    sfx_load(&s, SFXW_STEP2, A + "foley_footstep_gravel_3.wav", 0.3)
    sfx_load(&s, SFXW_STEP3, A + "foley_footstep_gravel_4.wav", 0.3)
    sfx_load(&s, SFXW_UI, A + "sci_fi_confirm.wav", 0.4)
    sfx_load(&s, SFXW_START, A + "sting_start.wav", 0.5)
    sfx_load(&s, SFXW_WIN, A + "sting_win.wav", 0.5)
    sfx_load(&s, SFXW_LOSE, A + "sting_lose.wav", 0.5)
    sfx_load(&s, SFXW_STING, A + "sting_blood.wav", 0.45)
    n := 0
    for o in s.ok { if o { n += 1 } }
    // wind bed underneath everything
    g_music = rl.LoadMusicStream("../assets/sfx/ambient_wind.wav")
    g_music_ok = true
    rl.SetMusicVolume(g_music, 0.3)
    rl.PlayMusicStream(g_music)
    fmt.printf("sfx: %d sounds + wind ready\n", n)
    return s
}

sfx_playi :: proc(idx: int) {
    if g_sfx.ready && g_sfx.ok[idx] {
        rl.PlaySound(g_sfx.bank[idx])
    }
}

// stride footsteps: call per fighter per frame (grounded + moving)
sfx_steps :: proc(f: ^Fighter, dt: f32) {
    if f.mode != .Anim || !f.grounded || f.speed < 2.0 { return }
    f.step_acc += f.speed * dt
    if f.step_acc > 1.6 {
        f.step_acc = 0
        sfx_playi(SFXW_STEP0 + int(f.step_idx % 4))
        f.step_idx += 1
    }
}
