// RS_Flashlight -- a torch that lights the air.
//
// The engine draws it: volumetricbeam.fp, a raymarched cone in view space, so
// each eye resolves its own matrix and stereo comes out right without the
// shader knowing VR exists. What this mod owns is whether it is on, where it is
// mounted, and what it looks like.
//
// IT TAKES SLOT 1 OF THIRTY-TWO. Slot 0 is where every caller that never passes
// a slot lands -- the weapon wheel's laser and the Lance still do -- so a torch
// on slot 0 fought them: whichever published last won, and the torch-off path
// erased their cone every tic. RS_VR_PistolTest's muzzle flashes sit at
// wm_flash_slot (4) + hand. The fog glow follows the lowest live slot, so the
// torch keeps it except while something on slot 0 is lit.
//
// PUBLISHED FROM UiTick, NOT WorldTick. The playsim freezes while a menu is
// open, so a beam published from WorldTick could not show a slider's change
// until the menu closed. The beam setters are clearscope for exactly this, and
// UiTick runs every tic whether or not a menu is up. The POSE is not ours at
// all: SetVolumetricBeamAnchor has the renderer read the hand or head every
// frame, so a hand torch does not step at 35 Hz behind a 90 Hz controller.
//
// THE SWITCH IS AN INVENTORY TOKEN, NOT A CVAR.
//
// A cvar lives on one machine. A token is playsim state: it is synchronised
// like anything else an actor carries and it saves with the game, so the whole
// game agrees whether your torch is on. Drawing it is another matter -- only
// the console player's own torch is published here, because the anchor reads
// the console player's pose.

class RSFL_Token : Inventory
{
	Default { Inventory.MaxAmount 1; +INVENTORY.UNDROPPABLE; +INVENTORY.UNTOSSABLE; }
}

class RSFL_Handler : EventHandler
{
	// Where the torch is mounted (rsfl_mount).
	const M_HEAD  = 0;   // looks where you look
	const M_HAND  = 1;   // the off hand, tracked separately in VR
	const M_GUN   = 2;   // the weapon hand, points where you aim

	const SLOT = 1;

	// SetVolumetricBeamAnchor modes.
	const A_MAINHAND = 1;
	const A_OFFHAND  = 2;
	const A_HEAD     = 3;

	// Whether this handler published the beam last tic. The torch-off path
	// clears only a beam it put there, never a slot somebody else is using.
	private ui bool held;

	override void NetworkProcess(ConsoleEvent e)
	{
		// The toggle comes through as a NETWORK EVENT rather than a console
		// command acting locally, which is what makes it arrive on every
		// client on the same tic. e.Player is who pressed it.
		if (e.Name != "rsfl_toggle") return;
		if (e.Player < 0 || e.Player >= MAXPLAYERS) return;

		let mo = players[e.Player].mo;
		if (!mo) return;

		if (mo.CountInv("RSFL_Token") > 0) mo.TakeInventory("RSFL_Token", 1);
		else                               mo.GiveInventory("RSFL_Token", 1);
	}

	override void UiTick()
	{
		Publish();
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// The engine resets beams on a map change too; this is the mod saying
		// so rather than relying on it.
		if (level) level.ClearVolumetricBeam(SLOT);
	}

	ui void Publish()
	{
		if (!level) return;

		let pmo = players[consoleplayer].mo;
		bool on = RSFL.GetB("rsfl_enabled", true)
			&& pmo && pmo.health > 0 && pmo.CountInv("RSFL_Token") > 0;
		if (!on)
		{
			Release();
			return;
		}

		int m = clamp(RSFL.GetI("rsfl_mount", M_HAND), M_HEAD, M_GUN);
		Vector3 ofs = (RSFL.GetF("rsfl_offset_fwd", 0.0),
			RSFL.GetF("rsfl_offset_side", 0.0),
			RSFL.GetF("rsfl_offset_z", -4.0));

		Vector3 org, dir;
		[org, dir] = ScriptPose(pmo, m, ofs);

		// The engine clamps these too, and logs when it has to. Keeping inner
		// under outer here means dragging one slider past the other just pins
		// it, rather than printing a clamp line every tic.
		double outer = clamp(RSFL.GetF("rsfl_outer", 26.0), 0.2, 89.0);
		double inner = clamp(RSFL.GetF("rsfl_inner", 11.0), 0.0, outer - 0.1);

		level.SetVolumetricBeam(org, dir,
			RSFL.Tint(),
			inner,
			outer,
			RSFL.GetF("rsfl_length", 1400.0),
			RSFL.GetF("rsfl_density", 0.5) * Flicker(),
			RSFL.GetF("rsfl_falloff", 1.8),
			RSFL.GetF("rsfl_dust", 0.45),
			RSFL.GetF("rsfl_dust_scale", 0.035),
			RSFL.GetF("rsfl_dust_drift", 0.35),
			SLOT);

		// AFTER SetVolumetricBeam: claiming a slot that was not live resets its
		// anchor. Anchored, the renderer takes both origin and direction from
		// the pose each frame, with ofs as (forward, right, up) in its frame.
		level.SetVolumetricBeamAnchor(SLOT, AnchorFor(m), ofs);
		held = true;
	}

	ui void Release()
	{
		if (!held) return;
		level.ClearVolumetricBeam(SLOT);
		held = false;
	}

	clearscope static int AnchorFor(int m)
	{
		if (m == M_HEAD) return A_HEAD;
		if (m == M_GUN)  return A_MAINHAND;
		return A_OFFHAND;
	}

	// The same pose the anchor resolves, worked out in script. The renderer
	// only uses it if the anchor cannot find a pose, but it has to be right
	// anyway, because a beam pointing somewhere else for one frame is a flash.
	//
	// THE ENGINE STORES HAND ANGLES OFFSET. AttackAngle and OffhandAngle are
	// world yaw MINUS 90, and AttackPitch and OffhandPitch are negated
	// (g_game.cpp, hw_vrmodes.cpp). Every reader adds the 90 back and flips the
	// pitch -- RS_WorldHands does, and the anchor does. Fed in raw, the torch
	// pointed 90 degrees right with its pitch upside down.
	//
	// Doom pitch is positive DOWN, so forward.z is -sin(pitch). The frame is
	// the anchor's own (hw_drawinfo.cpp ResolveVolBeamPose), so the offsets mean
	// the same thing whichever of the two positions the beam.
	clearscope static Vector3, Vector3 ScriptPose(PlayerPawn pmo, int m, Vector3 ofs)
	{
		double eyeZ = players[consoleplayer].viewz;
		Vector3 org;
		double yaw, pit;

		if (m == M_HAND)
		{
			org = pmo.OffhandPos;
			yaw = pmo.OffhandAngle + 90.0;
			pit = -pmo.OffhandPitch;
		}
		else if (m == M_GUN)
		{
			org = pmo.AttackPos;
			yaw = pmo.AttackAngle + 90.0;
			pit = -pmo.AttackPitch;
		}
		else
		{
			org = (pmo.pos.x, pmo.pos.y, eyeZ);
			yaw = pmo.angle;
			pit = pmo.pitch;
		}

		// A hand pose nobody has written yet is exactly (0,0,0). That, not a
		// zero ANGLE, is the "no pose" test: an angle of 0 is a real direction.
		if (org == (0, 0, 0))
		{
			org = (pmo.pos.x, pmo.pos.y, eyeZ);
			yaw = pmo.angle;
			pit = pmo.pitch;
		}

		double cp = cos(pit), sp = sin(pit);
		double cy = cos(yaw), sy = sin(yaw);
		Vector3 fwd   = (cp * cy, cp * sy, -sp);
		Vector3 right = (sy, -cy, 0);
		Vector3 up    = (sp * cy, sp * sy, cp);

		return org + fwd * ofs.x + right * ofs.y + up * ofs.z, fwd;
	}

	// A torch is not a studio light. A little unsteadiness costs nothing and is
	// most of what stops it reading as a cone somebody attached to your face.
	//
	// DETERMINISTIC, not random(). The RNG seed sum is in the netgame
	// consistency checksum, and a torch that rolled dice every tic would be
	// rolling them on every client -- fine if it happened identically, and
	// nothing worth risking for a wobble. sin of the map time is identical
	// everywhere by construction. It holds still while the game is paused.
	clearscope static double Flicker()
	{
		double amt = clamp(RSFL.GetF("rsfl_flicker", 0.08), 0.0, 1.0);
		if (amt <= 0.0) return 1.0;
		double t = level.maptime;
		double w = sin(t * 13.7) * 0.6 + sin(t * 31.3) * 0.4;
		return 1.0 + amt * w * 0.5;
	}
}

// ---- shared helpers --------------------------------------------------------
//
// Same shape as GITD_Util, RSD's, RSI_Util, RSDF, RSKC and RSF. These mods
// merge eventually and the copies collapse into one, which is only painless if
// they have not drifted.

class RSFL
{
	clearscope static double GetF(String n, double def = 0.0)
	{
		let c = CVar.FindCVar(n); return c ? c.GetFloat() : def;
	}
	clearscope static int GetI(String n, int def = 0)
	{
		let c = CVar.FindCVar(n); return c ? c.GetInt() : def;
	}
	clearscope static bool GetB(String n, bool def = false)
	{
		let c = CVar.FindCVar(n); return c ? c.GetBool() : def;
	}

	// ALWAYS alpha 255. A colour that loses its alpha is the most expensive bug
	// in this family of mods -- several draw paths gate on `.a > 0` and simply
	// stop, with no error anywhere.
	clearscope static Color Tint()
	{
		return Color(255,
			clamp(GetI("rsfl_r", 255), 0, 255),
			clamp(GetI("rsfl_g", 244), 0, 255),
			clamp(GetI("rsfl_b", 214), 0, 255));
	}
}
