/*
 * See Licensing and Copyright notice in naev.h
 */
#pragma once

#include "pilot.h"

#define PILOT_OUTFIT_LUA_UPDATE_DT     (1.0/10.0)   /* How often the Lua outfits run their update script (in seconds).  */

/* Augmentations of normal pilot API. */
const char* pilot_outfitDescription( const Pilot *pilot, const Outfit *o );
const char* pilot_outfitSummary( const Pilot *p, const Outfit *o, int withname );

/* Raw changes. */
int pilot_addOutfitRaw( Pilot* pilot, const Outfit* outfit, PilotOutfitSlot *s );
int pilot_addOutfitTest( Pilot* pilot, const Outfit* outfit, PilotOutfitSlot *s, int warn );
int pilot_rmOutfitRaw( Pilot* pilot, PilotOutfitSlot *s );

/* Changes with checks. */
int pilot_addOutfit( Pilot* pilot, const Outfit* outfit, PilotOutfitSlot *s );
int pilot_rmOutfit( Pilot* pilot, PilotOutfitSlot *s );

/* Intrinsic outfits. */
int pilot_addOutfitIntrinsic( Pilot *pilot, const Outfit *outfit );
int pilot_rmOutfitIntrinsic( Pilot *pilot, PilotOutfitSlot *s );

/* Ammo. */
int pilot_addAmmo( Pilot* pilot, PilotOutfitSlot *s, int quantity );
int pilot_rmAmmo( Pilot* pilot, PilotOutfitSlot *s, int quantity );
int pilot_countAmmo( const Pilot* pilot );
int pilot_maxAmmo( const Pilot* pilot );
int pilot_maxAmmoO( const Pilot* p, const Outfit *o );
void pilot_fillAmmo( Pilot* pilot );

/* Checks. */
int pilot_slotsCheckSafety( const Pilot *p );
int pilot_slotsCheckRequired( const Pilot *p );
int pilot_isSpaceworthy( const Pilot *p );
int pilot_reportSpaceworthy( const Pilot *p, char *buf, int buffSize );
const char* pilot_canEquip( const Pilot *p, const PilotOutfitSlot *s, const Outfit *o );

/* Lock-ons. */
void pilot_lockUpdateSlot( Pilot *p, PilotOutfitSlot *o, Pilot *t, double *a, double dt );
void pilot_lockClear( Pilot *p );

/* Other. */
void pilot_calcStats( Pilot *pilot );
void pilot_updateMass( Pilot *pilot );
void pilot_healLanded( Pilot *pilot );
PilotOutfitSlot *pilot_getSlotByName( Pilot *pilot, const char *name );

/* Special outfit stuff. */
int pilot_getMount( const Pilot *p, const PilotOutfitSlot *w, vec2 *v );

/* Lua outfit stuff. */
int pilot_slotIsToggleable( const PilotOutfitSlot *o );
int pilot_slotIsToggleable( const PilotOutfitSlot *o );
int pilot_outfitLAdd( Pilot *pilot, PilotOutfitSlot *po );
int pilot_outfitLRemove( Pilot *pilot, PilotOutfitSlot *po );
void pilot_outfitLInitAll( Pilot *pilot );
int pilot_outfitLInit( Pilot *pilot, PilotOutfitSlot *po );
void pilot_outfitLUpdate( Pilot *pilot, double dt );
void pilot_outfitLOutfofenergy( Pilot *pilot );
void pilot_outfitLOnhit( Pilot *pilot, double armour, double shield, unsigned int attacker );
int pilot_outfitLOntoggle( Pilot *pilot, PilotOutfitSlot *po, int on );
void pilot_outfitLCooldown( Pilot *pilot, int done, int success, double timer );
void pilot_outfitLOnshoot( Pilot *pilot );
int pilot_outfitLOnstealth( Pilot *pilot );
void pilot_outfitLOnscan( Pilot *pilot );
void pilot_outfitLOnscanned( Pilot *pilot, const Pilot *scanner );
void pilot_outfitLOnland( Pilot *pilot );
void pilot_outfitLOntakeoff( Pilot *pilot );
void pilot_outfitLOnjumpin( Pilot *pilot );
void pilot_outfitLCleanup( Pilot *pilot );
