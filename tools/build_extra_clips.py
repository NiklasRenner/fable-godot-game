"""Adds the extra animation clips to the character models (run once from the project root):
    python tools/build_extra_clips.py

The models' first clips come from their Meshy animation tasks (import_meshy.py model). These are
later picks from Meshy's library, animated on the same rigs into meshy/anim2/*_cand.glb (task ids
in meshy/hero.json and meshy/creatures.json), then pose-edited with `import_meshy.py tweak` and
copied in with `clips`:
    hero        idle_calm    NPCs' resting idle: Idle_12 with Idle_02's weight shift, arms at the
                             sides with bent elbows, breathing and sway (the restless "idle"
                             plays now and then, npc.gd)
                combat_idle  Combat_Stance, while in combat (Unit._idle_clip)
                walk         the run: Lean_Forward_Sprint with 25% more leg drive
    troll, boss combat_idle  Idle_10's low crouch with the arms mostly back to their own idle, so
                             they look ready to lunge rather than box
Safe to re-run: each clip is replaced, the rest of the model is untouched.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(__file__))
from import_meshy import cmd_clips, cmd_tweak  # noqa: E402

WORK = "meshy/anim2/_work"
LEGS = "Hips,Spine,*UpLeg,*Leg,*Foot,*ToeBase"
ARMS = "*Shoulder,*Arm,*ForeArm,*Hand"


def work_copy(name):
    os.makedirs(WORK, exist_ok=True)
    path = os.path.join(WORK, name)
    shutil.copy(os.path.join("meshy/anim2", name), path)
    return path


hero = work_copy("hero_cand.glb")
cmd_tweak(hero, "Idle_12", "idle_calm", [
    "blend:Idle_02:%s:0.6" % LEGS,
    # arms hang back at the sides with the elbows bent forward (Idle_12 holds them straight,
    # out and in front: half a T-pose from the game camera)
    "rot:LeftForeArm:28,0,0", "rot:RightForeArm:28,0,0", "rot:LeftArm:-15,0,0", "rot:RightArm:-11,0,0",
    # and it never quite stops: breathing, a slow weight sway, the head looking about, the arms
    # trailing the body
    "wave:Spine02:1.5,0,0:2", "wave:LeftShoulder,RightShoulder:1.2,0,0:2",
    "wave:Hips:0,0,1.2:1", "wave:*UpLeg:0,0,-1.2:1", "wave:Spine01:0,0,-1.0:1:0.1",
    "wave:Head:0,8,0:1:0.1", "wave:Head:1.5,0,0:2:0.3",
    "wave:LeftArm,RightArm:2.5,0,0:1:0.15", "wave:*ForeArm:3,0,0:2:0.3"])
cmd_tweak(hero, "Lean_Forward_Sprint_inplace", "run", [
    "amp:*UpLeg,*Leg,*Foot:1.25", "amp:*Arm,*ForeArm:1.15"])
cmd_clips("assets/hero.glb", hero, ["idle_calm:idle_calm", "Combat_Stance:combat_idle", "run:walk"])

for cand, model in [("troll_cand.glb", "assets/troll.glb"), ("boss_cand.glb", "assets/troll_boss.glb")]:
    path = work_copy(cand)
    cmd_clips(path, model, ["idle:base_idle"])
    cmd_tweak(path, "Idle_10", "combat_idle", [
        "blend:base_idle:%s:0.65" % ARMS, "blend:base_idle:Hips,*UpLeg,*Leg,*Foot:0.25",
        "rot:Spine02:6,0,0", "rot:Head:-6,0,0"])
    cmd_clips(model, path, ["combat_idle:combat_idle"])

shutil.rmtree(WORK)
