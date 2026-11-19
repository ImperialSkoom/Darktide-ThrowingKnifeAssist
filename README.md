# Throwing Knife Assist

Aim assistance for the Zealot's Blades of Faith in Warhammer 40,000: Darktide. Aim near a visible specialist or elite and press your blitz key. The mod selects a target and adjusts the throw for knife drop, drag, and estimated target movement. If it finds no eligible target, you can still throw manually.

## Installation

1. Set up the Darktide Mod Loader and Darktide Mod Framework (DMF).
2. Place the mod folder inside your game's `mods` directory. The entry file should be at `mods/ThrowingKnifeAssist/ThrowingKnifeAssist.mod`.
3. Add `ThrowingKnifeAssist` on its own line in `mods/mod_load_order.txt`, after `dmf`. If you use TakeAim, place ThrowingKnifeAssist after it as well.
4. Start Darktide, equip Blades of Faith on your Zealot, and open **Mod Options > Throwing Knife Assist**.

HoldKnife is optional and has overlapping blitz input handling. Leave it disabled when using the controls described here.

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| Enabled | On | Enables knife targeting and the mod's hold-to-throw handling. Turn it off for standard blitz input. |
| Aim point | Torso | Torso aims at the body. Weakspot (head) aims at the head node. If the preferred node is missing, the assist tries the other node, then the unit's root. |
| Hold to Throw | On | Hold the blitz key to repeat while knives are available. Release to stop new throws. Turn this off for one throw per press. |

## Target selection and accuracy

The assist checks visibility and searches up to 58 metres. Priority threats such as snipers, trappers, and hounds can be selected farther from the crosshair and take precedence over other eligible enemies. Bosses and ordinary horde enemies are excluded.

Torso gives the most margin against moving targets. Weakspot (head) follows the head aim node, so accuracy depends on the enemy's anatomy. The assist predicts the curved flight at release. Sudden movement can cause a miss, and overhead cover can intersect the arc even when there is a clear sightline to the target.
