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
//
// THE SPOT ON THE WALL IS A REAL DYNAMIC LIGHT, AND IT IS PLAYSIM STATE.
//
// The cone lights air; nothing in volumetricbeam.fp touches a wall, a floor or
// a monster. The spot is an attached SPOT light on the player pawn itself, so
// every client puts every player's spot on that player's pawn and the engine
// holds it in that player's own hand (SetAttachedLightAnchor reads the pawn's
// player). It is built from the PLAYER'S USERINFO, not the local cvars, so all
// machines draw your spot in your colour -- a local read would paint everyone
// else's torch in mine.
//
// A_AttachLight IS PLAY SCOPE, SO IT CANNOT RIDE THE UiTick PUBLISH. The beam
// setters are declared clearscope; the Actor light natives are not, and the
// compiler's scope barrier (scopebarrier.cpp AddFlags) refuses a ui or
// clearscope caller reaching a play method. So the spot is applied from play:
// WorldTick normally, and NetworkProcess while a menu has the playsim stopped.
// That still moves live: G_Ticker runs net commands every tic paused or not,
// and P_Ticker's paused branch rebuilds any lights flagged for it before the
// frame is drawn. The pose never waits on either -- the renderer re-poses
// anchored lights every frame.

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

	// The spot, per player: the pawn it was put on and the settings it was
	// last issued with. A_AttachLight flags the pawn's lights for a rebuild, so
	// the spot is re-issued only when something about it changed -- not 35
	// times a second for a light that is standing still. The pawn is kept so a
	// spot left on a body the player no longer drives (a morph, a respawn)
	// comes off that body instead of staying lit on it.
	private Array<Actor> spotOn;
	private Array<String> spotKey;

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Player < 0 || e.Player >= MAXPLAYERS) return;

		// Sent by SyncUnderMenu while a menu has the playsim stopped.
		if (e.Name == "rsfl_spot_sync")
		{
			ApplySpot(e.Player);
			return;
		}

		// The toggle comes through as a NETWORK EVENT rather than a console
		// command acting locally, which is what makes it arrive on every
		// client on the same tic. e.Player is who pressed it.
		if (e.Name != "rsfl_toggle") return;

		let mo = players[e.Player].mo;
		if (!mo) return;

		if (mo.CountInv("RSFL_Token") > 0) mo.TakeInventory("RSFL_Token", 1);
		else                               mo.GiveInventory("RSFL_Token", 1);

		// Now, not next WorldTick: the spot and the beam change on one tic.
		ApplySpot(e.Player);
	}

	override void UiTick()
	{
		Publish();
		SyncUnderMenu();
	}

	override void WorldTick()
	{
		for (int i = 0; i < MAXPLAYERS; i++) ApplySpot(i);
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// The engine resets beams on a map change too; this is the mod saying
		// so rather than relying on it.
		if (level) level.ClearVolumetricBeam(SLOT);

		// The pawn carries its lights to the next map. Take the spot off here
		// so none arrives lit somewhere this handler has never seen; the next
		// map's handler puts it back on its first tic.
		for (int i = 0; i < MAXPLAYERS; i++) RemoveSpot(i);
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

		double inner, outer;
		[inner, outer] = Cone(RSFL.GetF("rsfl_inner", 11.0), RSFL.GetF("rsfl_outer", 26.0));

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

	// WHILE A MENU HAS THE GAME STOPPED, ASK PLAY SCOPE TO LOOK AGAIN.
	//
	// WorldTick does not run under a pausing menu, and this ui path cannot call
	// A_AttachLight itself. A network event can reach it: G_Ticker executes net
	// commands every tic while P_Ticker sits paused, and the event lands in
	// NetworkProcess, which is play. A slider's new value arrives the same way
	// (a `user` cvar change is a userinfo net command), so the spot sees it a
	// tic or two after the drag. ApplySpot only rebuilds when a setting really
	// changed, so asking every tic under a menu costs a compare.
	//
	// Single player only. A netgame never pauses for a menu, WorldTick is
	// already doing this there, and the event would be traffic for nothing.
	// The title map does not pause either.
	ui void SyncUnderMenu()
	{
		if (netgame || gamestate != GS_LEVEL || menuactive == Menu.Off) return;
		if (!players[consoleplayer].mo) return;
		EventHandler.SendNetworkEvent("rsfl_spot_sync");
	}

	// The one place the spot is put on, reshaped or taken off a pawn.
	//
	// Every client runs this for every player with the same inputs -- the token,
	// health, the server switch and that player's userinfo -- so every machine
	// issues the same light. Look-only either way: no gameplay code reads a
	// dynamic light, and there is no random() anywhere near it.
	void ApplySpot(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		if (spotKey.Size() < MAXPLAYERS)
		{
			spotOn.Resize(MAXPLAYERS);
			spotKey.Resize(MAXPLAYERS);
		}

		PlayerPawn pmo = null;
		if (playeringame[pnum]) pmo = players[pnum].mo;

		// A spot left on a body this player no longer drives comes off it.
		if (spotOn[pnum] && spotOn[pnum] != pmo) RemoveSpot(pnum);

		bool on = pmo && pmo.health > 0
			&& RSFL.GetB("rsfl_enabled", true)
			&& pmo.CountInv("RSFL_Token") > 0;
		double bright = on ? clamp(RSFL.GetFP("rsfl_spot", pnum, 1.0), 0.0, 4.0) : 0.0;
		if (bright <= 0.0)
		{
			RemoveSpot(pnum);
			return;
		}

		int m = clamp(RSFL.GetIP("rsfl_mount", pnum, M_HAND), M_HEAD, M_GUN);
		Vector3 ofs = (RSFL.GetFP("rsfl_offset_fwd", pnum, 0.0),
			RSFL.GetFP("rsfl_offset_side", pnum, 0.0),
			RSFL.GetFP("rsfl_offset_z", pnum, -4.0));

		double inner, outer;
		[inner, outer] = Cone(RSFL.GetFP("rsfl_inner", pnum, 11.0), RSFL.GetFP("rsfl_outer", pnum, 26.0));

		Color col = RSFL.TintOf(pnum);

		// A dynamic light's size argument is HALF its reach -- FDynamicLight::
		// GetRadius doubles it -- so half the beam's length dies out where the
		// cone does. The engine then caps the argument at gl_light_max_intensity
		// (1000 by default), which is why a beam past about 2000 units reaches
		// further than its spot.
		int radius = clamp(int(RSFL.GetFP("rsfl_length", pnum, 1400.0) * 0.5), 16, 1024);

		// Attenuated, or the light is flat to the edge of its radius and reads
		// as a floor-wash. DONTLIGHTSELF because a torch does not light the
		// person holding it -- the lens sits inside the body's own bounds.
		int flags = DynamicLight.LF_SPOT | DynamicLight.LF_ATTENUATE | DynamicLight.LF_DONTLIGHTSELF;
		if (!RSFL.GetBP("rsfl_spot_shadows", pnum, true)) flags |= DynamicLight.LF_NOSHADOWMAP;

		String key = String.Format("%d %d %d %d %d %d %.2f %.2f %.3f %.2f %.2f %.2f",
			col.r, col.g, col.b, radius, flags, m, inner, outer, bright, ofs.x, ofs.y, ofs.z);
		if (spotOn[pnum] == pmo && spotKey[pnum] == key) return;

		// Same id every time, so this reshapes the one light rather than adding
		// a second. The anchor goes on again because the mount or the lens may
		// be what changed; while anchored the light takes position, yaw and
		// pitch from the pose, so the (0,0,0) offset and 0 pitch here are unused.
		pmo.A_AttachLight('RSFL_Torch', DynamicLight.PointLight, col, radius, 0, flags,
			(0, 0, 0), 0, inner, outer, 0, bright);
		pmo.SetAttachedLightAnchor('RSFL_Torch', AnchorFor(m), ofs);
		spotOn[pnum] = pmo;
		spotKey[pnum] = key;
	}

	// Take the spot off whatever pawn it was put on. A_RemoveLight is keyed by
	// id and the id is ours alone, so this never touches another mod's light
	// on the same pawn.
	//
	// The id is deliberately NOT spelled rsfl_...: menu_lint reads a quoted name
	// with the cvar prefix as a placement set and demands seven cvars for it.
	void RemoveSpot(int pnum)
	{
		if (pnum < 0 || pnum >= spotKey.Size()) return;
		if (spotOn[pnum]) spotOn[pnum].A_RemoveLight('RSFL_Torch');
		spotOn[pnum] = null;
		spotKey[pnum] = "";
	}

	// The engine clamps these too, and logs when it has to. Keeping inner
	// under outer here means dragging one slider past the other just pins it,
	// rather than printing a clamp line every tic.
	//
	// The spot takes the same pair, so the patch on the wall is the cone's own
	// footprint: both are half-angles from the axis, and volumetricbeam.fp and
	// the dynamic light shader both smoothstep between their cosines.
	clearscope static double, double Cone(double inner, double outer)
	{
		double o = clamp(outer, 0.2, 89.0);
		return clamp(inner, 0.0, o - 0.1), o;
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

	// PER-PLAYER READS, for anything built into the playsim for every player
	// rather than drawn for this machine alone. A `user` cvar is userinfo:
	// CVar.GetCVar given a player returns that player's copy, which every
	// machine holds. FindCVar would hand back this machine's value for all.
	clearscope static double GetFP(String n, int pnum, double def = 0.0)
	{
		let c = CVar.GetCVar(n, players[pnum]); return c ? c.GetFloat() : def;
	}
	clearscope static int GetIP(String n, int pnum, int def = 0)
	{
		let c = CVar.GetCVar(n, players[pnum]); return c ? c.GetInt() : def;
	}
	clearscope static bool GetBP(String n, int pnum, bool def = false)
	{
		let c = CVar.GetCVar(n, players[pnum]); return c ? c.GetBool() : def;
	}

	// Tint(), from a player's userinfo. Alpha 255 for the same reason.
	clearscope static Color TintOf(int pnum)
	{
		return Color(255,
			clamp(GetIP("rsfl_r", pnum, 255), 0, 255),
			clamp(GetIP("rsfl_g", pnum, 244), 0, 255),
			clamp(GetIP("rsfl_b", pnum, 214), 0, 255));
	}
}
