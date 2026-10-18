# Development

The README covers packing and playing. This page is for working on nxnative itself: how it is built, the script's options, running games on the Mac, adding a game, and per-game notes. Agent-oriented details (bring-up failure catalogue, graphics specifics, debugging recipes) are in [docs/agents](agents/README.md).

## How it works

| Part | State |
|---|---|
| Rewriter (`dm/tools/patch_nso.py`, `DM_RULESET=native`) | Runs unchanged on every module of every supported game. Per-build cuts are keyed by the module's build ID |
| Host (`dm/host`) | Stands in for the Horizon kernel and the system services the games call: threads and synchronization, memory, file system with transactional saves, HID, audio, movies (VP9 through libvpx, Vorbis sound through stb_vorbis), software keyboard, focus and lifecycle |
| Graphics (`dm/gfx`) | NVN on Metal. Shaders are extracted by `shader_split.py` from Nintendo's containers and from Unity's `Shader` objects, then translated offline. Mario: 16,266 of 16,268 shaders compile. Engage: 9,268 of 9,269 |
| Audio | Games that carry the SDK's audio renderer (Mario) run it in-process; games that use AudioOut directly (Engage: Wwise) feed it straight. Output goes through Core Audio (default on iOS, `DM_AUDIO=1` on the Mac) |
| Input | iOS: the touch gamepad and physical controllers. Mac: scripted input (`DM_KEYS=<seconds>:<button>,…`, with `DM_KBD=<text>` answering the system keyboard) or `DM_WINDOW=1` for a window with keyboard input and physical controllers (face buttons by the letter macOS reports, so a Switch Pro Controller's A is A; the Pro Controller's HOME light, which macOS keeps on, is switched off, `DM_PAD_HOME_LED=1` leaves it). Its motion and rumble go through raw HID: GameController reports only zeros for its motion and CoreHaptics cannot play the game's HD rumble, so the host reads the IMU from the controller's input reports (nn::hid six-axis) and sends the game's vibration values as HD rumble output reports, peak-held per 15 ms and raised by a curve (`DM_PAD_RUMBLE=<exponent>`, default 0.5; 1 = raw). `DM_PAD_LOG=1` logs stick, motion and rumble) |
| iOS app | One unsigned IPA for iPhone and iPad. The rewritten code is embedded in the executable; the shader libraries, the RomFS and the game icon are inside the app |
| Known gaps | Conditional render is always drawn; sparse virtual-pool mappings; `DrawElementsIndirect`. TBDR optimizations are off by default (they don't understand bindless textures yet). No amiibo. The bundled prewarm lists are empty. On the Mac, Mario's menu and dialogue text render blank (fine on the iPhone) |

## The packing script in detail

`scripts/build_ipa_from_nsp.py` (`-h` lists every option):

```
# written to the Desktop with your own home-screen name
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys -o ~/Desktop/Mario.ipa --app-name "Mario Wonder"

# pack Mario 1.0.0 instead of 1.2.1 (the folder still needs both NSPs: the shader tables cover both versions)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys -p v0

# keep the extracted game files (to run the game on the Mac, or to skip extraction next time)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys --keep-extracted

# a diagnostic build with environment switches baked in (one KEY=VALUE per line)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys --env-file diag_env.txt
```

In Spyder, open the script, fill in the settings at the top (`NSP_DIR`, `PROD_KEYS`, and optionally `PACKAGE`, `OUT_IPA`, `APP_NAME`, `BUNDLE_ID`), and press F5. Empty paths are asked for at run time.

What the script does:
1. It finds the game profile from the title ID (the `[title ID]` in the file names, or the NSP's ticket; the update by its `[vN]` tag).
2. It extracts the NSPs.
3. It rewrites the code modules, checking each build ID against the profile.
4. It splits out the shaders and checks them against the profile's tables.
5. It builds the iOS shader libraries.
6. It calls `build_ipa.sh`.

Everything it writes stays in the NSP folder: intermediate files and logs in `<id>_build/`, the IPA next to the NSPs. The extracted game files are deleted at the end unless you pass `--keep-extracted`. It exits with 0 when done and 1 on an error. The app's bundle ID is `org.nxnative.<base game title ID>` (for example `org.nxnative.0100a6301214e000`), and its version is the game's display version: the update's when an update is packed, else the base game's (Engage 2.0.0); `--app-name` / `--bundle-id` (or `APP_NAME` / `BUNDLE_ID` in Spyder) override the name and ID.

On the device, environment switches go in `Documents/env.txt` (one `KEY=VALUE` per line), and game files are also accepted at `Documents/romfs`.

## Port another game

Each game has a profile in `dm/games/<id>/`:
- `game.tsv` holds the title ID, known builds, code modules, RomFS marker, memory split, NVN driver tables, app name and bundle ID;
- the shader tables: `shader_map.tsv`, `shader_facts.tsv`, `shader_pairs.tsv`, `c1_full.tsv`, `pso_manifest.tsv`;
- `dmsh_chain.h` holds the chain version.

The shader tools pick a profile with `DM_GAME=<id>`; `make -C dm/host` and `build_ipa.sh` pick it with `GAME=<id>`. Profiles are named after the base game's title ID. There is no default game: without `GAME` / `DM_GAME` the tools stop and list the profiles. `python3 dm/games/game.py list` lists the profiles. Host code that relies on one build's fixed addresses checks that build's ID.

To add a game:
1. Run `scripts/build_ipa_from_nsp.py` on its NSP folder. With no matching profile, it writes a survey to `<title ID>_survey/survey.md`. The survey covers the modules, SDK, engine, containers, rewrite sites, and the imports compared with the host's hooks. It then guesses a provisional profile from the survey into `<title ID>_build/profile/<title ID>/` (outside the repository; tools find it through `DM_GAMES_DIR`), generates its shader tables and chain header, and packs a best-effort IPA that may not boot. `--survey-only` stops after the survey, and `--profile-out` puts the profile elsewhere. Details in [dm/games/README.md](../dm/games/README.md).
2. Add a profile as described in [dm/games/README.md](../dm/games/README.md).
3. Bring the game up following [docs/agents](agents/README.md): extraction, binary survey, a catalogue of host bring-up failures, graphics, and debugging recipes.

## Build by hand (Mac)

You need the same tools as the script. The shader translator is the prebuilt `dm/gfx/tools/dmsh_xlate_bin`, the build that matches `dmsh_chain.lock`; a fresh `dotnet publish` gives different fingerprints. The commands use three variables:
- `G`, the profile;
- `W`, the game's work folder: `<title ID>-work` inside the game's NSP folder, outside this repository and off the home folder (it grows to the size of the game files);
- `VER`, a version folder named after the NSP version.

```
G=010015100B514000; W="<NSP folder>/$G-work"; VER=v327680
# 1. extract: the base game alone (update -), or an update layered over it (the last argument lets unchanged files become clones)
dotnet build dm/tools/nx_extract -c Release -o $W/build/nx_extract
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> - $W/data/v0
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> <update NSP> $W/data/$VER $W/data/v0/RomFS
# 2. rewrite the profile's code modules
for m in $(python3 dm/games/game.py $G modules); do DM_RULESET=native python3 dm/tools/patch_nso.py $W/data/$VER/ExeFS/$m $W/build/patched_$VER $m; done
# 3. shaders: extract from every version in the profile's shader_versions (comma-separated, base first), then translate into <cache>/b-<chain version>/
DM_GAME=$G python3 dm/gfx/tools/shader_split.py $W/data/v0/RomFS,$W/data/$VER/RomFS $W/data/v0/ExeFS/main,$W/data/$VER/ExeFS/main $W/shader/pkg dm/games/$G/shader_map.tsv dm/games/$G/shader_facts.tsv dm/games/$G/shader_pairs.tsv
DM_GAME=$G python3 dm/gfx/tools/dmsh_chain.py --header
DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
python3 dm/gfx/tools/c1_guard.py $W/build/cache/metal_shader_cache/b-<chain version> dm/games/$G/c1_full.tsv
# 4. the host, and the button-icon font for the Nintendo-extension shared font
make -C dm/host GAME=$G dmhost
python3 dm/tools/make_ext_font.py $W/build/font/nintendo_ext.ttf
# 5. run on the Mac
DM_ROOT=$W DM_ROMFS=$W/data/$VER/RomFS DM_SAVE=$W/run/save DM_TEMP=$W/run/temp DM_MSL_DIR=$W/build/cache/metal_shader_cache DM_FONT_DIR=$W/build/font dm/host/dmhost $W/build/patched_$VER
# 6. iOS shader libraries (about 15 min for Mario), then the IPA (default <NSP folder>/<the profile's ipa>)
IOSOUT=$W/build/ios/dmsh_b DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
GAME=$G W=$W dm/ios/tools/build_ipa.sh [out.ipa]
```

Notes on these steps:
- `build_ipa.sh` takes the rewritten modules from `$W/build/patched_<package>` and the RomFS from `$W/data/<package>/RomFS`; `PATCHED` and `ROMFS` override them.
- It also bundles a standard font (macOS's Arial Unicode, `STD_FONT=` overrides it) and the generated `nintendo_ext.ttf`.
- The icon is the `icon.jpg` that `nx_extract` saves next to `RomFS/`; `DM_ICON=` points at another image.
- `DM_ENV_FILE=` bakes environment switches into the app, and `DM_DISPLAY_NAME=` renames it.
- If Xcode's Locations setting puts products in a custom place, the script finds the app through the build log.
- hactool cannot read every update (Mario 1.2.1's patch NCA gives "Invalid BKTR layout!"), which is why `nx_extract` uses LibHac.

## Prewarm lists

Metal compiles each combination of shaders and pipeline settings for the GPU the first time it is used. Each takes tens of milliseconds, so a burst of them on entering a level is a visible freeze. The host records what it had to compile and rebuilds those pipelines on a background queue at the next launch:

- `pso_user.tsv` sits next to the save directory: `Documents/pso_user.tsv` on iOS, the parent of `DM_SAVE` on the Mac (`DM_PSO_USER=path` overrides it). It is appended while playing, one line per item built on the spot: a shader (`S`), a render pipeline (`R`, the hex of `pso_skey` in `dm/gfx/nvn/nvn_pso_skey.h`) or a compute pipeline (`C`).
- `dm/games/<id>/pso_manifest.tsv` is the seed list bundled with the app, prewarmed before `pso_user.tsv`.

The lines name shaders by content key and hold no compiled code and nothing personal, so a list recorded on one device works on any other. To seed the bundled list:
1. Record on the Mac with prewarm off, so everything is built on demand: `DM_PSO_MANIFEST=off DM_PSO_RECORD=<file>`, playing the scenes players reach first. Engage's list covers boot, the opening movie, the title, a save load and the prologue battle.
2. Append the recorded lines below the header comments, in the recorded order. Duplicates are dropped at load.
3. Rebuild the IPA.

Record on the game version you ship. At launch the log names each list it read and its line count (`管线预热清单 … 行`), or says that `pso_user.tsv` does not exist yet.

## Game notes

**Super Mario Bros. Wonder (`010015100B514000`)**
- **Versions:** v0 (1.0.0) and 1.2.1 (v327680). With the update layered over v0, unchanged files become APFS clones, so the merged RomFS adds only about 114 MB to the 3.5 GB base.
- **Shaders:** 12,811 in v0 and 16,268 across both versions; the tables hold both.
- **1.2.1:** it is a new `main` build (SDK 16.2.12), whose resource-heap cut (+16 KB slack) was carried over with `dm/tools/nso_fnmap.py`. It also makes new SDK calls, which the host answers: `nn::nfp` finds no amiibo, `pl::IsRunningOnOunce` is false, the shop call is a no-op, and `account::PopOpenUsers` returns none.
- **Mac input:** `DM_KEYS="12:A,14:A,20:A,26:A,32:A"` reaches the opening course.

**Fire Emblem Engage (`0100A6301214E000`)**
- **Engine:** Unity 2020.3 IL2CPP, SDK 12.3.7. The shaders are read out of Unity bundles (`unityfs.py`).
- **Memory:** a 5 GB guest block, the total proven on a phone, with a 2.5 GB application pool. A per-build cut shrinks the SDK's address-region node area to 62 MB.
- **Audio:** Wwise drives AudioOut directly.
- **Movies:** VP9, decoded on the host.
- **60 fps:** the Switch version runs at 30; one patch to its code switches it to the 60 fps timing the game already has, so nothing runs too fast.

**The Legend of Zelda: Breath of the Wild (`01007EF00011E000`)**
- A patch to the game's frame-interval logic lifts its 30 fps limit to 60 without changing the speed of what runs on the game's variable frame rate (it falls back to 30 by itself when a frame takes too long). Systems that count frames instead run twice as fast at 60. Pre-rendered cutscenes (the `Movie/Demo*.webm` files, e.g. the Great Plateau tower rising) ended while their sound played on: the game's player shows every frame it gets, so the profile's `movie_pace` makes the host's movie decoder release each video frame only when its timestamp is due. The decoder writes each frame into the game's texture from the movie thread; uploads of such textures now take a CPU snapshot under the same lock as the write (an upload caught mid-write showed a garbled frame every few seconds). sead's controller repeat (`pad_repeat_step`, the host keeps its step at present interval / 2) now follows the frame rate too. Still open: the weapon wheel's own stick repeat (full tilt held 0.3 s: 4 slots at 60 fps, 2 at 30) is not that repeat and still runs twice as fast.
- The game waits for each frame's GPU work before submitting the next, so the host hands its translated commands to the GPU in segments ([04](agents/04-graphics.md)).
- **HUD prompt shadows and glows:** each prompt bar captures itself into a blurred mask the game keeps in the red channel of an R8 texture whose channel mapping says alpha = 1; the profile's `alpha_from_red` key makes every layout shader read such render targets as (1, 1, 1, R) like the library's own A8 textures, otherwise prompts sit on hard-edged dark boxes or cream cloud rectangles and the stamina wheel is black ([04](agents/04-graphics.md)).
- **Sky:** the atmospheric scattering table is a 3D texture the CPU fills directly in memory; the host uploads such a texture when it finds data in it, otherwise the sky is flat grey over a sunlit landscape ([04](agents/04-graphics.md)).
- **Menu background:** the game copies the scene through a view whose alpha is mapped to 0 and draws blurred copies blended by that alpha; the profile's `alpha_one` key gives the copies into RGB10A2 targets alpha = 1, otherwise the menus sit on black instead of the blurred scene and the weapon wheel's slots are white (the HUD's RGBA8 captures keep the 0 as their mask) ([04](agents/04-graphics.md)).
- **Sun shadows:** the shadow cascades are drawn with depth clamp on (`nvnCommandBufferSetDepthClamp`), replayed as Metal's depth clip mode; without it tree shadows were cut off near Link and roofs let the sun through indoors ([04](agents/04-graphics.md)).

**The Legend of Zelda: Link's Awakening (`01006BB00C6F0000`)**
- **Engine:** Grezzo's engine on NintendoWare, SDK 8.2.0 (the oldest so far), NVN 53. Modules main + subsdk0 (GLSLC, NVN's runtime shader compiler) + subsdk1 (movie) + sdk; 9,698 shaders from the bfsha archives, effects and layouts.
- **Window origin:** the only game so far that keeps NVN's default lower-left (OpenGL) window origin; the host flips its viewports and winding and the window image at present ([04](agents/04-graphics.md)). Before that, text the game renders into textures came out upside down.
- **Vertex inputs:** some prepass shaders take the same input as integers in one draw and as Half / normalized data in another, or both in one draw; the build keeps a float-declared variant `<key>_bv` and the host picks or mixes by the bound formats ([04](agents/04-graphics.md)). Before that, trees had no canopies.
- **Movies:** VP9 with a 5.1 Vorbis sound track; the host decodes the sound with stb_vorbis.
- **Lighting:** tiled forward lighting whose tile lists a compute shader builds each frame; it needs the dispatch size in NVN's driver segment `c0` ([04](agents/04-graphics.md)). Before the host supplied it, lights piled into the bottom tile row and the doorway step flickered with white tiles.
- **Sound:** SDK 8 numbers the audio renderer's commands differently (the output command is 0x10, not 0x13); the host recognises the output command by its size. Before that, music and sound effects were silent and only the movies had sound ([03](agents/03-bringup.md)).
- **Mac input:** the title wants L+R: `DM_KEYS="f6000:L+R~0.4,f6300:A,f6500:A,f6700:Down,f6800:A"` reaches a new file's name entry (a fresh save directory via `SV=`).
- **Frame rate:** gameplay runs at 60 like on the Switch; the game itself drops to 30 (present interval 2) for event cutscenes.
- **Depth of field:** outdoors the game blurs the top and bottom of the screen by depth. It sets NVN's near = 0 depth mode, which the shader translation now follows for every game (an entry point per mode, picked at run time); before that the whole screen was blurred ([04](agents/04-graphics.md)).
- **Sunlight:** outdoors the sun's shadow test failed everywhere, so the scene was dim and nothing cast a shadow. The world position its shaders pass between stages has no w written, and the translation filled it with 0 instead of the hardware's 1; every game's shaders now get the hardware's default ([04](agents/04-graphics.md)).
- **Physics:** at 30 fps the game steps physics twice per frame. Its completion task destroys itself after it runs, and on Apple devices that destructor could land after the next step had already rebuilt the task, so the physics workers crashed when a conversation or cutscene began. A per-build cut drops the destructor call ([03](agents/03-bringup.md)).

**Super Mario Odyssey (`0100000000010000`), being ported**
- **Engine:** Nintendo EPD's sead / agl with NintendoWare, SDK 7.3.2 (the oldest so far), update 1.4.1. Modules main + subsdk0 (movie) + sdk; 27,984 shaders (agl `sharcb` and `bfsha` in `ShaderData`, particles in `EffectData`); its three geometry shaders (a thunder effect) do not translate.
- **Start-up services:** it calls several system services no other game did, each answered by the host: the aborting `account::OpenPreselectedUser` and `GetLastOpenedUser`, news delivery (`bcat`: the delivery storage does not mount, which the game treats as "nothing delivered"), HOME-button blocking, the parental 3D-mode setting, `vi::SetLayerScalingMode`, `time::ToPosixTimeFromUtc`, the debug pad, and the SDK 7 names of two audio-device calls ([03](agents/03-bringup.md)).
- **Movies:** MP4 / H.264 (the videos in its tutorial hint boxes, the kingdom travel videos), 41 of 44 High or Main profile with B-frames. The host decodes them with VideoToolbox; the SDK's demuxer passes the parameter sets as the `avcc` record (the MP4 `avcC` box), and pictures leave in presentation order through a small queue.
- **Sticks:** the game reads all 16 entries of the controller history whatever count comes back; the host now fills every entry (before, only the first, and neither stick did anything in play while buttons and menus worked).
- **HUD:** the coin counters are layout panes that take their alpha from single-channel render targets, as in Breath of the Wild; the profile lists the 26 layout shaders under `alpha_from_red` (before, they were solid white cards).
- **Ground:** a depth pre-pass followed by a less-or-equal G-buffer pass needs bit-identical positions from different vertex shaders; every shader is now compiled with `-fpreserve-invariance` (before, the Cap Kingdom ground showed stale 32×32 blocks on every fourth frame) ([04](agents/04-graphics.md)).

**Hades (`0100535012974000`), being ported**
- **Engine:** Supergiant's engine on The Forge renderer, SDK 9.3.0, update 1.0.38233. It renders with **Vulkan**: `main` imports 100 `vk*` functions from subsdk0 (the Vulkan loader, over NVIDIA's driver in subsdk1). The host implements them on Metal itself (`dm/gfx/vk/hle_vk.m`), so only main and sdk are loaded; the profile says `graphics vulkan`.
- **Vulkan layer:** one Tegra X1-like device (Vulkan 1.1); device memory is a shared `MTLBuffer` made on first use, images are their own textures; command buffers are recorded and replayed into one Metal command buffer per submit on the layer's own queue; swapchain images are shown through the NVN layer's present path once their frame's GPU work is done. Names the game asks for through `vkGet*ProcAddr` are logged once each.
- **Shaders:** 74 SPIR-V files in `Content/EffectsForgeSwitch`. `dm/gfx/tools/vk_shaders.py <RomFS> <shader dir> [--ios <dir>]` translates them with SPIRV-Cross into `<dir>/vk/`: one library, and a table of the Metal slot each (set, binding) moved to. The game hands the same words to `vkCreateShaderModule`, so the host finds each shader by the hash of its SPIR-V.
- **Notification event:** the game polls `oe::GetNotificationMessageEvent` every frame; the SDK's own event was never created (the host's `oe::Initialize` is a no-op), so the host now hands out an event of its own, signalled while a notification is queued.
- **Online:** its `EOS_*` imports (Epic Online Services, an NRO it would load through `nn::ro`) stay offline.
- **Mac input:** `DM_KEYS="f800:A,f1000:A,f1200:A,f1500:A,f1900:A"` goes through the title and the intro into Tartarus.
- **Packing:** the NSP script does not translate Vulkan shaders yet. Run `vk_shaders.py` with `--ios <work folder>/build/ios/dmsh_b`, then `build_ipa.sh` (see [Build by hand](#build-by-hand-mac)).

## Tools (`dm/tools`)

| Tool | What it does |
|---|---|
| `nx_extract/` | NSP or XCI → ExeFS / RomFS / icon with LibHac, merging an update over the base game (C#, `dotnet build`). Contents are picked by their content meta records, so one XCI can serve as base, update and DLC; `--list` prints those records (type, title ID, version). `--manifest` writes ExeFS and a RomFS file list only, for surveys |
| `nso_fnmap.py` | Carries offsets from one build to another (function matching with addresses masked; globals via their references) |
| `nso2elf.py` | Converts NSO to ELF for Ghidra / REA |
| `insn_census.py` | Counts the instruction sites the rewriter must handle |
| `nso_syms.py` | Compares the SDK import surface of two games, or of one game (`-` for the reference) with the host hooks |
| `nvn_slots_got.py` | Builds the NVN fetch table and call sites (GOT-indirect loaders) |
