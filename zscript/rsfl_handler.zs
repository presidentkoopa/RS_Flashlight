// RS_Flashlight -- a torch that lights the air.
//
// The engine draws it: volumetricbeam.fp, a raymarched cone in view space, so
// each eye resolves its own matrix and stereo comes out right without the
// shader knowing VR exists. What this mod owns is whether it is on, where it is
// mounted, and what it looks like.
//
// IT TAKES SLOT 0. There are four volumetric beam slots and the flashlight is
// the one that is on for hours at a time, so it takes the lowest and leaves the
// others for things that flash. Before slots existed, opening the weapon wheel
// would take the beam away and closing it would switch the torch off.
//
// Slot is left to its default of 0 rather than written out; either is fine.
//
// THE SWITCH IS AN INVENTORY TOKEN, NOT A CVAR.
//
// A cvar lives on one machine. In a netgame nobody else's client would know
// your torch was on, so nobody else would ever see it. A token is playsim
// state: it is synchronised like anything else an actor carries, it saves with
// the game, and every client can read every player's. That is the whole reason
// other people can see your light at all.

class RSFL_Token : Inventory
{
	Default { Inventory.MaxAmount 1; +INVENTORY.UNDROPPABLE; +INVENTORY.UNTOSSABLE; }
}

class RSFL_Handler : EventHandler
{
	// Where the torch is mounted.
	const M_HEAD  = 0;   // looks where you look
	const M_HAND  = 1;   // the off hand, tracked separately in VR
	const M_GUN   = 2;   // clipped to the weapon, points where you aim

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

	override void WorldTick()
	{
		if (!level) return;

		if (!RSFL.GetB("rsfl_enabled", true))
		{
			level.ClearVolumetricBeam(0);
			return;
		}

		// One beam, and it is yours. Other players' torches would each want a
		// slot of their own and there are four in total -- see the note in
		// doombase.zs. Rendering everyone's is a knob rather than a given
		// because each live cone is a raymarch over the pixels it covers.
		let pmo = players[consoleplayer].mo;
		if (!pmo || pmo.health <= 0 || pmo.CountInv("RSFL_Token") <= 0)
		{
			level.ClearVolumetricBeam(0);
			return;
		}

		Vector3 org, dir;
		[org, dir] = Mount(pmo);

		level.SetVolumetricBeam(org, dir,
			RSFL.Tint(),
			RSFL.GetF("rsfl_inner", 11.0),
			RSFL.GetF("rsfl_outer", 26.0),
			RSFL.GetF("rsfl_length", 1400.0),
			RSFL.GetF("rsfl_density", 0.5) * Flicker(pmo),
			RSFL.GetF("rsfl_falloff", 1.8),
			RSFL.GetF("rsfl_dust", 0.45),
			RSFL.GetF("rsfl_dust_scale", 0.035),
			RSFL.GetF("rsfl_dust_drift", 0.35));
	}

	override void WorldUnloaded(WorldEvent e)
	{
		if (level) level.ClearVolumetricBeam(0);
	}

	// Where it sits and where it points.
	//
	// The mount is the whole VR question. Head-mounted always points where you
	// look, which is comfortable and slightly useless -- the beam is exactly
	// where your attention already is, and a cone seen end-on is a disc. The
	// off hand is the one worth having: you can light a doorway while aiming
	// somewhere else, and it is the reading the shader's own axis-fade note
	// describes as "the shot actually worth having".
	Vector3, Vector3 Mount(PlayerPawn pmo)
	{
		int m = RSFL.GetI("rsfl_mount", M_HAND);
		double up = RSFL.GetF("rsfl_offset_z", -4.0);
		double side = RSFL.GetF("rsfl_offset_side", 0.0);

		// AttackPos is the real muzzle -- the hand, in this fork's VR path --
		// and AttackAngle/AttackPitch the direction it is actually pointing.
		// On a flat screen they track the view, which is why the head and gun
		// mounts collapse to the same thing there.
		double ang, pit;
		Vector3 org;

		if (m == M_HEAD)
		{
			org = pmo.pos + (0, 0, pmo.height * 0.9 + up);
			ang = pmo.angle;
			pit = pmo.pitch;
		}
		else
		{
			// Hand and gun both read the attack origin. They differ in whether
			// the mod applies a side offset, which is what puts a hand torch
			// off the aim axis and stops it washing the middle of the frame.
			org = pmo.AttackPos;
			if (org == (0, 0, 0)) org = pmo.pos + (0, 0, pmo.height * 0.8);
			ang = pmo.AttackAngle != 0 ? pmo.AttackAngle : pmo.angle;
			pit = pmo.AttackPitch != 0 ? pmo.AttackPitch : pmo.pitch;
			org.z += up;
			if (m == M_HAND && side != 0)
				org += (cos(ang + 90) * side, sin(ang + 90) * side, 0);
		}

		double cp = cos(-pit);
		Vector3 dir = (cos(ang) * cp, sin(ang) * cp, sin(-pit));
		return org, dir;
	}

	// A torch is not a studio light. A little unsteadiness costs nothing and is
	// most of what stops it reading as a cone somebody attached to your face.
	//
	// DETERMINISTIC, not random(). The RNG seed sum is in the netgame
	// consistency checksum, and a torch that rolled dice every tic would be
	// rolling them on every client -- fine if it happened identically, and
	// nothing worth risking for a wobble. sin of the map time is identical
	// everywhere by construction.
	double Flicker(Actor mo)
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
