/*
 * See Licensing and Copyright notice in naev.h
 */
#pragma once

#include "outfit.h"
#include "pilot.h"
#include "player.h"

/**
 * Custom slot widget.
 */
typedef struct CstSlotWidget_ {
   PlayerShip_t *selected; /**< Selected pilot ship. */
   Outfit *outfit; /**< Selected outfit. */
   int slot; /**< Selected equipment slot. */
   int mouseover; /**< Mouse over slot. */
   double altx; /**< Alt X text position. */
   double alty; /**< Alt Y text position. */
   int canmodify; /**< Whether or not it can modify stuff. */
   int weapons; /**< Hack to render colours for currently selected weapon set. */
} CstSlotWidget; /**< Slot widget. */

/*
 * Main.
 */
void equipment_open( unsigned int wid );
void equipment_cleanup (void);

/*
 * Misc.
 */
void equipment_addAmmo (void);
void equipment_regenLists( unsigned int wid, int outfits, int ships );
void equipment_updateShips( unsigned int wid, const char* str );
void equipment_updateOutfits( unsigned int wid, const char* str );
int equipment_shipStats( char *buf, int max_len,  const Pilot *s, int dpseps, int name );
void equipment_slotWidget( unsigned int wid,
      double x, double y, double w, double h,
      CstSlotWidget *data );
void equipment_slotDeselect( CstSlotWidget *wgt );
