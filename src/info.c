/*
 * See Licensing and Copyright notice in naev.h
 */
/**
 * @file info.h
 *
 * @brief Handles the info menu.
 */
/** @cond */
#include "naev.h"
/** @endcond */

#include "info.h"

#include "array.h"
#include "dialogue.h"
#include "equipment.h"
#include "gui.h"
#include "hook.h"
#include "land.h"
#include "log.h"
#include "map.h"
#include "menu.h"
#include "mission.h"
#include "ndata.h"
#include "nlua.h"
#include "nlua_tk.h"
#include "nstring.h"
#include "ntime.h"
#include "pilot.h"
#include "player.h"
#include "player_fleet.h"
#include "player_gui.h"
#include "shiplog.h"
#include "space.h"
#include "tk/toolkit_priv.h"
#include "toolkit.h"

#define BUTTON_WIDTH    135 /**< Button width, standard across menus. */
#define BUTTON_HEIGHT   30 /**< Button height, standard across menus. */

#define SETGUI_WIDTH    400 /**< GUI selection window width. */
#define SETGUI_HEIGHT   300 /**< GUI selection window height. */

#define menu_Open(f)    (menu_open |= (f)) /**< Marks a menu as opened. */
#define menu_Close(f)   (menu_open &= ~(f)) /**< Marks a menu as closed. */

#define INFO_WINDOWS      7 /**< Amount of windows in the tab. */

#define INFO_WIN_MAIN      0
#define INFO_WIN_SHIP      1
#define INFO_WIN_WEAP      2
#define INFO_WIN_CARGO     3
#define INFO_WIN_MISN      4
#define INFO_WIN_STAND     5
#define INFO_WIN_SHIPLOG   6
static const char *info_names[INFO_WINDOWS] = {
   N_("Main"),
   N_("Ship"),
   N_("Weapons"),
   N_("Cargo"),
   N_("Missions"),
   N_("Standings"),
   N_("Ship log"),
}; /**< Name of the tab windows. */

/**
 * @brief For use with registered info buttons.
 */
typedef struct InfoButton_s {
   int id;        /**< Unique ID. */
   char *caption; /**< Button caption. */
   char button[32]; /**< Current button caption. */
   int priority;  /**< Button priority. */
   /* Lua stuff .*/
   nlua_env env;  /**< Runtime environment. */
   int func;      /**< Function to call. */
   SDL_Keycode key; /**< Hotkey (or SDLK_UNKNOWN==0 if none). */
} InfoButton_t;
static InfoButton_t *info_buttons = NULL;

static unsigned int info_wid = 0;
static unsigned int *info_windows = NULL;
static int info_lastTab;   /**< Last open tab. */

static CstSlotWidget info_eq;
static CstSlotWidget info_eq_weaps;
static int *info_factions;

static int selectedMission = 0;  /**< Current index in the missions list-box. */
static int selectedLog = 0;
static int selectedLogType = 0;
static char **logTypes=NULL;
static int ntypes=0;
static int nlogs=0;
static char **logs=NULL;
static int *logIDs=NULL;
static int logWidgetsReady=0;

/*
 * prototypes
 */
/* information menu */
static void info_close( unsigned int wid, const char *str );
static void info_openMain( unsigned int wid );
static void info_setGui( unsigned int wid, const char *str );
static void setgui_load( unsigned int wdw, const char *str );
static void info_toggleGuiOverride( unsigned int wid, const char *name );
static void info_openShip( unsigned int wid );
static void info_openWeapons( unsigned int wid );
static void info_openCargo( unsigned int wid );
static void info_openMissions( unsigned int wid );
static void info_getDim( unsigned int wid, int *w, int *h, int *lw );
static void info_buttonClick( unsigned int wid, const char *str );
static void standings_close( unsigned int wid, const char *str );
static void ship_update( unsigned int wid );
static void weapons_genList( unsigned int wid );
static void weapons_update( unsigned int wid, const char *str );
static void weapons_autoweap( unsigned int wid, const char *str );
static void weapons_fire( unsigned int wid, const char *str );
static void weapons_inrange( unsigned int wid, const char *str );
static void aim_lines( unsigned int wid, const char *str );
static void weapons_renderLegend( double bx, double by, double bw, double bh, void* data );
static void info_openStandings( unsigned int wid );
static void info_shiplogView( unsigned int wid, const char *str );
static void standings_update( unsigned int wid, const char *str );
static void cargo_genList( unsigned int wid );
static void cargo_update( unsigned int wid, const char *str );
static void cargo_jettison( unsigned int wid, const char *str );
static void mission_menu_abort( unsigned int wid, const char *str );
static void mission_menu_genList( unsigned int wid, int first );
static void mission_menu_update( unsigned int wid, const char *str );
static void info_openShipLog( unsigned int wid );
static const char* info_getLogTypeFilter( int lstPos );
static void info_changeTab( unsigned int wid, const char *str, int old, int new );

static int sort_buttons( const void *p1, const void *p2 )
{
   const InfoButton_t *b1 = p1;
   const InfoButton_t *b2 = p2;
   if (b1->priority < b2->priority)
      return -1;
   else if (b1->priority > b2->priority)
      return +1;
   return strcmp(b1->caption,b2->caption);
}

static void info_buttonFree( InfoButton_t *btn )
{
   free( btn->caption );
   luaL_unref( naevL, LUA_REGISTRYINDEX, btn->func );
}

static void info_buttonRegen (void)
{
   int wid;
   if (info_wid == 0)
      return;
   wid = info_windows[ INFO_WIN_MAIN ];
   for (int i=0; i<array_size(info_buttons); i++) {
      InfoButton_t *btn = &info_buttons[i];
      snprintf( btn->button, sizeof(btn->button), "btnExtra%d", i );
      if (widget_exists( wid, btn->button ))
         window_destroyWidget( wid, btn->button );
      window_addButtonKey( wid, -20 - (i+2)*(20+BUTTON_WIDTH), 20,
            BUTTON_WIDTH, BUTTON_HEIGHT,
            btn->button, btn->caption, info_buttonClick, btn->key );
   }
}

/**
 * @brief Registers a button in the info menu.
 *
 *    @param caption Caption to give the button.
 *    @param priority Button priority, lower is more important.
 *    @param key Hotkey for using the button without it being focused (or SDLK_UNKNOWN or 0 if none).
 *    @return Newly created button ID.
 */
int info_buttonRegister( const char *caption, int priority, SDL_Keycode key )
{
   static int button_idgen = 0;
   int id;
   InfoButton_t *btn;

   if (info_buttons == NULL)
      info_buttons = array_create( InfoButton_t );

   btn = &array_grow( &info_buttons );
   btn->id     = ++button_idgen;
   btn->caption= strdup( caption );
   btn->button[0] = '\0';
   btn->priority = priority;
   btn->env    = __NLUA_CURENV;
   btn->func   = luaL_ref( naevL, LUA_REGISTRYINDEX );
   btn->key    = key;

   id = btn->id;
   qsort( info_buttons, array_size(info_buttons), sizeof(InfoButton_t), sort_buttons );

   info_buttonRegen();
   return id;
}

/**
 * @brief Unregisters a button in the info menu.
 *
 *    @param id ID of the button to unregister and previously created by info_buttonRegister.
 *    @return 0 on success.
 */
int info_buttonUnregister( int id )
{
   for (int i=0; i<array_size(info_buttons); i++) {
      InfoButton_t *btn = &info_buttons[i];
      if (btn->id != id)
         continue;
      if (info_wid != 0) {
         int wid = info_windows[ INFO_WIN_MAIN ];
         if (widget_exists( wid, btn->button ))
            window_destroyWidget( wid, btn->button );
      }
      info_buttonFree( btn );
      array_erase( &info_buttons, btn, btn+1 );
      info_buttonRegen();
      return 0;
   }
   return -1;
}

/**
 * @brief Clears all te registered buttons.
 */
void info_buttonClear (void)
{
   for (int i=0; i<array_size(info_buttons); i++) {
      InfoButton_t *btn = &info_buttons[i];
      if (info_wid != 0) {
         int wid = info_windows[ INFO_WIN_MAIN ];
         if (widget_exists( wid, btn->button ))
            window_destroyWidget( wid, btn->button );
      }
      info_buttonFree( btn );
   }
   array_free( info_buttons );
   info_buttons = NULL;
   info_buttonRegen();
}

static void info_buttonClick( unsigned int wid, const char *str )
{
   (void) wid;
   for (int i=0; i<array_size(info_buttons); i++) {
      InfoButton_t *btn = &info_buttons[i];
      if (strcmp( btn->button, str )!=0)
         continue;

      lua_rawgeti( naevL, LUA_REGISTRYINDEX, btn->func );
      if (nlua_pcall( btn->env, 0, 0 )) {
         WARN( _("Failure to run info button with id '%d':\n%s"), btn->id, lua_tostring( naevL, -1 ) );
         lua_pop( naevL, 1 );
      }
      return;
   }
}

/**
 * @brief Opens the information menu.
 */
void menu_info( int window )
{
   int w, h;
   const char *names[INFO_WINDOWS];

   /* Not under manual control. */
   if (pilot_isFlag( player.p, PILOT_MANUAL_CONTROL ))
      return;

   /* Open closes when previously opened. */
   if (menu_isOpen(MENU_INFO) || dialogue_isOpen()) {
      if ((info_wid > 0) && !window_isTop(info_wid))
         return;
      info_close( 0, NULL );
      return;
   }

   /* Dimensions. */
   w = 640;
   h = 600;

   /* Create the window. */
   info_wid = window_create( "wdwInfo", _("Info"), -1, -1, w, h );
   window_setCancel( info_wid, info_close );

   /* Create tabbed window. */
   for (size_t i=0; i<INFO_WINDOWS; i++)
      names[i] = _(info_names[i]);
   info_windows = window_addTabbedWindow( info_wid, -1, -1, -1, -1, "tabInfo",
         INFO_WINDOWS, names, 0 );

   /* Open the subwindows. */
   info_openMain(       info_windows[ INFO_WIN_MAIN ] );
   info_openShip(       info_windows[ INFO_WIN_SHIP ] );
   info_openWeapons(    info_windows[ INFO_WIN_WEAP ] );
   info_openCargo(      info_windows[ INFO_WIN_CARGO ] );
   info_openMissions(   info_windows[ INFO_WIN_MISN ] );
   info_openStandings(  info_windows[ INFO_WIN_STAND ] );
   info_openShipLog(    info_windows[ INFO_WIN_SHIPLOG ] );

   menu_Open(MENU_INFO);

   /* Opening hooks. */
   hooks_run("info");

   /* Set active window. */
   window_tabWinOnChange( info_wid, "tabInfo", info_changeTab );
   if (window == INFO_DEFAULT)
      window = info_lastTab;
   window_tabWinSetActive( info_wid, "tabInfo", CLAMP( 0, 6, window ) );
}
/**
 * @brief Closes the information menu.
 *    @param str Unused.
 */
static void info_close( unsigned int wid, const char *str )
{
   (void) wid;
   if (info_wid > 0) {
      info_lastTab = window_tabWinGetActive( info_wid, "tabInfo" );

      window_close( info_wid, str );
      info_wid = 0;
      info_windows = NULL;
      logs = NULL;
      menu_Close(MENU_INFO);
   }
}

/**
 * @brief Updates the info windows.
 */
void info_update (void)
{
   if (info_windows != NULL)
      weapons_genList( info_windows[ INFO_WIN_WEAP ] );
}

/**
 * @brief Opens the main info window.
 */
static void info_openMain( unsigned int wid )
{
   const char **buf;
   char str[STRMAX_SHORT], creds[ECON_CRED_STRLEN];
   char **licenses;
   int nlicenses;
   char *nt;
   int w, h, cargo_used, cargo_total;
   unsigned int destroyed;
   size_t k = 0, l = 0;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Compute ships destroyed. */
   destroyed = 0;
   for (int i=0; i<SHIP_CLASS_TOTAL; i++)
      destroyed += player.ships_destroyed[i];

   /* pilot generics */
   nt = ntime_pretty( ntime_get(), 2 );
   k += scnprintf( &str[k], sizeof(str)-k, "%s", _("Pilot:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Date:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n\n%s", _("Money:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Current Ship:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Fuel:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", (player.fleet_capacity > 0) ? _("Cargo (fleet):") : _("Cargo:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n\n%s", _("Time played:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Times died:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Times jumped:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Times landed:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Damage done:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Damage taken:") );
   k += scnprintf( &str[k], sizeof(str)-k, "\n%s", _("Ships destroyed:") );
   window_addText( wid, 20, 20, 120, h-80, 0, "txtDPilot", &gl_smallFont, &cFontGrey, str );

   credits2str( creds, player.p->credits, 2 );
   l += scnprintf( &str[l], sizeof(str)-l, "%s", player.name );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", nt );
   l += scnprintf( &str[l], sizeof(str)-l, "\n\n%s", creds );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", player.p->name );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%.0f (%d %s)",
         player.p->fuel, pilot_getJumps(player.p), n_( "jump", "jumps", pilot_getJumps(player.p) ) );
   cargo_used = pfleet_cargoUsed();
   cargo_total = cargo_used + pfleet_cargoFree();
   l += scnprintf( &str[l], sizeof(str)-l, "\n%d / %d %s", cargo_used, cargo_total, n_( "tonne", "tonnes", cargo_total ) );
   l += scnprintf( &str[l], sizeof(str)-l, "%s", "\n\n" );
   l += scnprintf( &str[l], sizeof(str)-l, _("%.1f hours"), player.time_played / 3600. );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", num2strU((double)player.death_counter,0) );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", num2strU((double)player.jumped_times, 0) );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s\n", num2strU((double)player.landed_times, 0) );
   l += scnprintf( &str[l], sizeof(str)-l, _("%s MJ"), num2strU(player.dmg_done_shield + player.dmg_done_armour, 0) );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", "" );
   l += scnprintf( &str[l], sizeof(str)-l, _("%s MJ"), num2strU(player.dmg_taken_shield + player.dmg_taken_armour, 0) );
   l += scnprintf( &str[l], sizeof(str)-l, "\n%s", num2strU(destroyed, 0) );
   window_addText( wid, 160, 20,
         w-80-160-40+20-180, h-80,
         0, "txtPilot", &gl_smallFont, NULL, str );
   free(nt);

   /* menu */
   window_addButton( wid, -20, 20,
         BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnClose", _("Close"), info_close );
   window_addButtonKey( wid, -20 - (20+BUTTON_WIDTH), 20,
         BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnSetGUI", _("Set GUI"), info_setGui, SDLK_g );

   for (int i=0; i<array_size(info_buttons); i++) {
      InfoButton_t *btn = &info_buttons[i];
      snprintf( btn->button, sizeof(btn->button), "btnExtra%d", i );
      window_addButtonKey( wid, -20 - (i+2)*(20+BUTTON_WIDTH), 20,
            BUTTON_WIDTH, BUTTON_HEIGHT,
            btn->button, btn->caption, info_buttonClick, btn->key );
   }

   buf = player_getLicenses();
   nlicenses = array_size( buf );
   /* List. */
   if (nlicenses == 0) {
     licenses = malloc(sizeof(char*));
     licenses[0] = strdup(_("None"));
   } else {
     licenses = malloc(sizeof(char*) * nlicenses);
     for (int i=0; i<nlicenses; i++)
        licenses[i] = strdup( _(buf[i]) );
      qsort( licenses, nlicenses, sizeof(char*), strsort );
   }
   window_addText( wid, -20, -40, w-80-240-40-40, 20, 1, "txtList",
         NULL, NULL, _("Licenses") );
   window_addList( wid, -20, -70, w-80-240-40-40, h-110-BUTTON_HEIGHT,
         "lstLicenses", licenses, MAX(nlicenses, 1), 0, NULL, NULL );
   window_setFocus( wid, "lstLicenses" );
}

/**
 * @brief Closes the GUI selection menu.
 *
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void setgui_close( unsigned int wdw, const char *str )
{
   (void) str;
   window_destroy( wdw );
}

/**
 * @brief Allows the player to set a different GUI.
 *
 *    @param wid Window id.
 *    @param name of widget.
 */
static void info_setGui( unsigned int wid, const char *str )
{
   (void) str;
   char **guis;
   int nguis;
   char **gui_copy;

   /* Get the available GUIs. */
   guis = player_guiList();
   nguis = array_size( guis );

   /* In case there are none. */
   if (guis == NULL) {
      WARN(_("No GUI available."));
      dialogue_alert( _("There are no GUI available, this means something went wrong somewhere. Inform the Naev maintainer.") );
      return;
   }

   /* window */
   wid = window_create( "wdwSetGUI", _("Select GUI"), -1, -1, SETGUI_WIDTH, SETGUI_HEIGHT );
   window_setCancel( wid, setgui_close );

   /* Copy GUI. */
   gui_copy = malloc( sizeof(char*) * nguis );
   for (int i=0; i<nguis; i++)
      gui_copy[i] = strdup( guis[i] );

   /* List */
   window_addList( wid, 20, -50,
         SETGUI_WIDTH-BUTTON_WIDTH/2 - 60, SETGUI_HEIGHT-110,
         "lstGUI", gui_copy, nguis, 0, NULL, NULL );
   toolkit_setList( wid, "lstGUI", gui_pick() );

   /* buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH/2, BUTTON_HEIGHT,
         "btnBack", _("Close"), setgui_close );
   window_addButton( wid, -20, 30 + BUTTON_HEIGHT, BUTTON_WIDTH/2, BUTTON_HEIGHT,
         "btnLoad", _("Load"), setgui_load );

   /* Checkboxes */
   window_addCheckbox( wid, 20, 20,
         BUTTON_WIDTH, BUTTON_HEIGHT, "chkOverride", _("Override GUI"),
         info_toggleGuiOverride, player.guiOverride );
   info_toggleGuiOverride( wid, "chkOverride" );

   /* default action */
   window_setAccept( wid, setgui_load );
}

/**
 * @brief Loads a GUI.
 *
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void setgui_load( unsigned int wdw, const char *str )
{
   (void) str;
   int wid = window_get( "wdwSetGUI" );
   const char *gui = toolkit_getList( wid, "lstGUI" );

   if (strcmp(gui,_("None")) == 0)
      return;

   if (player.guiOverride == 0) {
      if (dialogue_YesNo( _("GUI Override is not set."),
               _("Enable GUI Override and change GUI to '%s'?"), gui )) {
         player.guiOverride = 1;
         window_checkboxSet( wid, "chkOverride", player.guiOverride );
      }
      else {
         return;
      }
   }

   /* Set the GUI. */
   free( player.gui );
   player.gui = strdup( gui );

   /* Close menus before loading for proper rendering. */
   setgui_close(wdw, NULL);

   /* Load the GUI. */
   gui_load( gui_pick() );
}

/**
 * @brief GUI override was toggled.
 *
 *    @param wid Window id.
 *    @param name of widget.
 */
static void info_toggleGuiOverride( unsigned int wid, const char *name )
{
   player.guiOverride = window_checkboxState( wid, name );
   /* Go back to the default one. */
   if (player.guiOverride == 0)
      toolkit_setList( wid, "lstGUI", gui_pick() );
}

/**
 * @brief Shows the player what outfits he has.
 *
 *    @param str Unused.
 */
static void info_openShip( unsigned int wid )
{
   int w, h;
   char buf[STRMAX];
   size_t l = 0;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Buttons */
   window_addButton( wid, -20, 20,
         BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeOutfits", _("Close"), info_close );

   /* Text. */
   l += scnprintf( &buf[l], sizeof(buf)-l, "%s", _("Name:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Model:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Class:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Crew:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Mass:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Jump Time:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Thrust:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Speed:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Turn:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Time Constant:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Absorption:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Shield:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Armour:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Energy:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Cargo Space:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Fuel:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _("Stats:") );
   window_addText( wid, 20, -40, 100, h-60, 0, "txtSDesc", &gl_smallFont, &cFontGrey, buf );
   window_addText( wid, 160, -40, w-20-20-20-160-180., h-60, 0, "txtDDesc", &gl_smallFont,
         NULL, NULL );

   /* Custom widget. */
   equipment_slotWidget( wid, -20, -40, 180, h-60, &info_eq );
   info_eq.selected  = player.p;
   info_eq.canmodify = 0;

   /* Update ship. */
   ship_update( wid );
}

/**
 * @brief Updates the ship stuff.
 */
static void ship_update( unsigned int wid )
{
   char buf[STRMAX_SHORT], *hyp_delay;
   size_t l = 0;
   int cargo = pilot_cargoUsed( player.p ) + pilot_cargoFree( player.p );

   hyp_delay = ntime_pretty( pilot_hyperspaceDelay( player.p ), 2 );
   /* Generic */
   l += scnprintf( &buf[l], sizeof(buf)-l, "%s", player.p->name );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _(player.p->ship->name) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", _(ship_class(player.p->ship)) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%d", (int)floor(player.p->crew) );
   /* Movement. */
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%.0f %s", player.p->solid->mass, n_( "tonne", "tonnes", player.p->solid->mass ) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%s average"), hyp_delay );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f kN/tonne"), player.p->thrust / player.p->solid->mass );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f m/s (max %.0f m/s)"),
         player.p->speed, solid_maxspeed( player.p->solid, player.p->speed, player.p->thrust ) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f deg/s"), player.p->turn*180./M_PI );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%.0f%%", player.p->stats.time_mod * player.p->ship->dt_default * 100. );
   /* Health. */
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%.0f%%", player.p->dmg_absorb * 100. );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f / %.0f MJ (%.1f MW)"), player.p->shield, player.p->shield_max, player.p->shield_regen );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f / %.0f MJ (%.1f MW)"), player.p->armour, player.p->armour_max, player.p->armour_regen );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%s", "" );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("%.0f / %.0f MJ (%.1f MW)"), player.p->energy, player.p->energy_max, player.p->energy_regen );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%d / %d %s", pilot_cargoUsed( player.p ), cargo, n_( "tonne", "tonnes", cargo ) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n%.0f / %.0f %s (%d %s)",
         player.p->fuel, player.p->fuel_max, n_( "unit", "units", player.p->fuel_max ),
         pilot_getJumps(player.p), n_( "jump", "jumps", pilot_getJumps(player.p) ) );
   l += scnprintf( &buf[l], sizeof(buf)-l, "%s", "\n\n" );

   equipment_shipStats( &buf[l], sizeof(buf)-l, player.p, 0, 0 );
   window_modifyText( wid, "txtDDesc", buf );
   free( hyp_delay );
}

/**
 * @brief Opens the weapons window.
 */
static void info_openWeapons( unsigned int wid )
{
   int w, h, x, y, wlen;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Custom widget. */
   equipment_slotWidget( wid, 20, -40, 180, h-60, &info_eq_weaps );
   info_eq_weaps.selected  = player.p;
   info_eq_weaps.weapons = 0;
   info_eq_weaps.canmodify = 0;

   /* Custom widget for legend. */
   y = -220;
   window_addCust( wid, 220, y, w-200-60, 100, "cstLegend", 0,
         weapons_renderLegend, NULL, NULL, NULL, NULL );

   /* Checkboxes. */
   wlen = w - 220 - 20;
   x = 220;
   y -= 100;
   window_addText( wid, x, y, wlen, 20, 0, "txtLocal", NULL, NULL,
         _("Current Weapon Set Settings"));
   y -= 20;
   window_addCheckbox( wid, x+10, y, wlen, BUTTON_HEIGHT,
         "chkFire", _("Enable instant Mode"), weapons_fire,
         (pilot_weapSetTypeCheck( player.p, info_eq_weaps.weapons )==WEAPSET_TYPE_WEAPON) );
   y -= 30;
   window_addText( wid, x+10, y, wlen, 20, 0, "txtSInstant", NULL, NULL, _("(Weapons fire when this weapon set key is pressed)"));
   y -= 20;
   window_addCheckbox( wid, x+10, y, wlen, BUTTON_HEIGHT,
         "chkInrange", _("Only shoot weapons that are in range"), weapons_inrange,
         pilot_weapSetInrangeCheck( player.p, info_eq_weaps.weapons ) );
   y -= 40;
   window_addText( wid, x, y, wlen, 20, 0, "txtGlobal", NULL, NULL,
         _("Global Settings"));
   y -= 20;
   window_addCheckbox( wid, x+10, y, wlen, BUTTON_HEIGHT,
         "chkAutoweap", _("Automatically handle weapons"), weapons_autoweap, player.p->autoweap );
   y -= 30;
   window_addCheckbox( wid, x+10, y, wlen, BUTTON_HEIGHT,
         "chkHelper", _("Dogfight aiming helper"), aim_lines, player.p->aimLines );

   /* List. Has to be generated after checkboxes. */
   weapons_genList( wid );

   /* Buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeCargo", _("Close"), info_close );
}

/**
 * @brief Generates the weapons list.
 */
static void weapons_genList( unsigned int wid )
{
   char **buf, tbuf[STRMAX_SHORT];
   int n, w, h;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Destroy widget if needed. */
   if (widget_exists( wid, "lstWeapSets" )) {
      window_destroyWidget( wid, "lstWeapSets" );
      n = toolkit_getListPos( wid, "lstWeapSets" );
   }
   else
      n = -1;

   /* List */
   buf = malloc( sizeof(char*) * PILOT_WEAPON_SETS );
   for (int i=0; i<PILOT_WEAPON_SETS; i++) {
      const char *str = pilot_weapSetName( info_eq_weaps.selected, i );
      if (str == NULL)
         snprintf( tbuf, sizeof(tbuf), "%d - ??", (i+1)%10 );
      else
         snprintf( tbuf, sizeof(tbuf), "%d - %s", (i+1)%10, str );
      buf[i] = strdup( tbuf );
   }
   window_addList( wid, 20+180+20, -40,
         w - (20+180+20+20), 180,
         "lstWeapSets", buf, PILOT_WEAPON_SETS,
         0, weapons_update, NULL );
   window_setFocus( wid, "lstWeapSets" );

   /* Restore position. */
   if (n >= 0)
      toolkit_setListPos( wid, "lstWeapSets", n );
}

/**
 * @brief Updates the weapon sets.
 */
static void weapons_update( unsigned int wid, const char *str )
{
   (void) str;
   int pos;

   /* Update the position. */
   pos = toolkit_getListPos( wid, "lstWeapSets" );
   if (pos < 0)
      return;
   info_eq_weaps.weapons = pos;

   /* Update fire mode. */
   window_checkboxSet( wid, "chkFire",
         (pilot_weapSetTypeCheck( player.p, pos ) == WEAPSET_TYPE_WEAPON) );

   /* Update inrange. */
   window_checkboxSet( wid, "chkInrange",
         pilot_weapSetInrangeCheck( player.p, pos ) );

   /* Update autoweap. */
   window_checkboxSet( wid, "chkAutoweap", player.p->autoweap );
}

/**
 * @brief Toggles autoweap for the ship.
 */
static void weapons_autoweap( unsigned int wid, const char *str )
{
   /* Set state. */
   int state = window_checkboxState( wid, str );

   /* Run autoweapons if needed. */
   if (state) {
      int sure = dialogue_YesNoRaw( _("Enable autoweapons?"),
            _("Are you sure you want to enable automatic weapon groups for the "
            "ship?\n\nThis will overwrite all manually-tweaked weapons groups.") );
      if (!sure) {
         window_checkboxSet( wid, str, 0 );
         return;
      }
      player.p->autoweap = 1;
      pilot_weaponAuto( player.p );
      weapons_genList( wid );
   }
   else
      player.p->autoweap = 0;
}

/**
 * @brief Sets the fire mode.
 */
static void weapons_fire( unsigned int wid, const char *str )
{
   int i, state, t, c;

   /* Set state. */
   state = window_checkboxState( wid, str );

   /* See how to handle. */
   t = pilot_weapSetTypeCheck( player.p, info_eq_weaps.weapons );
   if (t == WEAPSET_TYPE_ACTIVE)
      return;

   if (state)
      c = WEAPSET_TYPE_WEAPON;
   else
      c = WEAPSET_TYPE_CHANGE;
   pilot_weapSetType( player.p, info_eq_weaps.weapons, c );

   /* Check to see if they are all fire groups. */
   for (i=0; i<PILOT_WEAPON_SETS; i++)
      if (!pilot_weapSetTypeCheck( player.p, i ))
         break;

   /* Not able to set them all to fire groups. */
   if (i >= PILOT_WEAPON_SETS) {
      dialogue_alert( _("You can not set all your weapon sets to fire groups!") );
      pilot_weapSetType( player.p, info_eq_weaps.weapons, WEAPSET_TYPE_CHANGE );
      window_checkboxSet( wid, str, 0 );
   }

   /* Set default if needs updating. */
   pilot_weaponSetDefault( player.p );

   /* Must regen. */
   weapons_genList( wid );
}

/**
 * @brief Sets the inrange property.
 */
static void weapons_inrange( unsigned int wid, const char *str )
{
   int state = window_checkboxState( wid, str );
   pilot_weapSetInrange( player.p, info_eq_weaps.weapons, state );
}

/**
 * @brief Sets the aim lines property.
 */
static void aim_lines( unsigned int wid, const char *str )
{
   int state = window_checkboxState( wid, str );
   player.p->aimLines = state;
}

/**
 * @brief Renders the legend.
 */
static void weapons_renderLegend( double bx, double by, double bw, double bh, void* data )
{
   (void) data;
   (void) bw;
   (void) bh;
   double y;

   y = by+bh-20;
   gl_print( &gl_defFont, bx, y, &cFontWhite, p_("info", "Legend") );

   y -= 20.;
   toolkit_drawRect( bx, y, 10, 10, &cFontBlue, NULL );
   gl_print( &gl_smallFont, bx+20, y, &cFontWhite, _("Outfit that can be activated") );

   y -= 20.;
   toolkit_drawRect( bx, y, 10, 10, &cFontYellow, NULL );
   gl_print( &gl_smallFont, bx+20, y, &cFontWhite, _("Secondary Weapon (Right click toggles)") );

   y -= 20.;
   toolkit_drawRect( bx, y, 10, 10, &cFontRed, NULL );
   gl_print( &gl_smallFont, bx+20, y, &cFontWhite, _("Primary Weapon (Left click toggles)") );
}

/**
 * @brief Shows the player their cargo.
 *
 *    @param str Unused.
 */
static void info_openCargo( unsigned int wid )
{
   int w, h;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeCargo", _("Close"), info_close );
   window_addButton( wid, -40 - BUTTON_WIDTH, 20,
         BUTTON_WIDTH, BUTTON_HEIGHT, "btnJettisonCargo", _("Jettison"),
         cargo_jettison );
   window_disableButton( wid, "btnJettisonCargo" );

   /* Description. */
   window_addText( wid, 20, -40-200-20,
         w - 40, h - BUTTON_HEIGHT - 260, 0,
         "txtCargoDesc", NULL, NULL, NULL );

   /* Generate the list. */
   cargo_genList( wid );
}
/**
 * @brief Generates the cargo list.
 */
static void cargo_genList( unsigned int wid )
{
   char **buf;
   int nbuf;
   int w, h;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* Destroy widget if needed. */
   if (widget_exists( wid, "lstCargo" ))
      window_destroyWidget( wid, "lstCargo" );

   /* List */
   if (array_size(player.p->commodities)==0) {
      /* No cargo */
      buf = malloc(sizeof(char*));
      buf[0] = strdup(_("None"));
      nbuf = 1;
   }
   else {
      /* List the player fleet's cargo. */
      PilotCommodity *pclist = pfleet_cargoList();
      buf = malloc( sizeof(char*) * array_size(player.p->commodities) );
      for (int i=0; i<array_size(pclist); i++) {
         PilotCommodity *pc = &pclist[i];
         int misn = pc->id != 0;
         int illegal = (array_size(pc->commodity->illegalto)>0);

         asprintf(&buf[i], "%s %d%s%s",
               _(pc->commodity->name),
               pc->quantity,
               misn ? _(" [#bMission#0]") : "",
               illegal ? _(" (#rillegal#0)") : "" );
      }
      nbuf = array_size(player.p->commodities);
      array_free(pclist);
   }
   window_addList( wid, 20, -40,
         w - 40, 200,
         "lstCargo", buf, nbuf, 0, cargo_update, NULL );
   window_setFocus( wid, "lstCargo" );
}
/**
 * @brief Updates the player's cargo in the cargo menu.
 *    @param str Unused.
 */
static void cargo_update( unsigned int wid, const char *str )
{
   (void) str;
   char desc[STRMAX];
   int pos, l;
   const Commodity *com;
   PilotCommodity *pclist = pfleet_cargoList();

   if (array_size(pclist) <= 0) {
      array_free(pclist);
      return; /* No cargo, redundant check */
   }

   /* Can jettison all but mission cargo when not landed*/
   if (landed)
      window_disableButton( wid, "btnJettisonCargo" );
   else
      window_enableButton( wid, "btnJettisonCargo" );

   pos = toolkit_getListPos( wid, "lstCargo" );
   com = pclist[pos].commodity;

   if (!com->description)
      l = scnprintf( desc, sizeof(desc), "%s", _(com->name) );
   else
      l = scnprintf( desc, sizeof(desc), "%s\n\n%s", _(com->name), _(com->description) );

   /* Only add fleet information with fleet capacity. */
   if (player.fleet_capacity > 0) {
      l += scnprintf( &desc[l], sizeof(desc)-l, "\n\n%s", _("Carried by the following ships in your fleet:\n") );
      PFleetCargo *plist = pfleet_cargoListShips( com );
      for (int i=0; i<array_size(plist); i++)
         l += scnprintf( &desc[l], sizeof(desc)-l, _("\n   - %s (%d)"), plist[i].p->name, plist[i].q );
      array_free(plist);
   }

   /* Add message on illegal outfits. */
   if (array_size(com->illegalto) > 0) {
      l += scnprintf( &desc[l], sizeof(desc)-l, "\n\n%s", _("Illegalized by the following factions:\n") );
      for (int i=0; i<array_size(com->illegalto); i++) {
         int f = com->illegalto[i];
         if (!faction_isKnown(f))
            continue;

         l += scnprintf( &desc[l], sizeof(desc)-l, _("\n   - %s"), _(faction_name(f)) );
      }
   }
   window_modifyText( wid, "txtCargoDesc", desc );

   array_free(pclist);
}
/**
 * @brief Makes the player jettison the currently selected cargo.
 *    @param str Unused.
 */
static void cargo_jettison( unsigned int wid, const char *str )
{
   (void)str;
   int pos, ret;
   Mission *misn;
   PilotCommodity *pclist = pfleet_cargoList();

   if (array_size(pclist) <= 0) {
      array_free(pclist);
      return; /* No cargo, redundant check */
   }

   pos = toolkit_getListPos( wid, "lstCargo" );

   /* Special case mission cargo. */
   if (pclist[pos].id != 0) {
      int f;

      if (!dialogue_YesNo( _("Abort Mission"),
               _("Are you sure you want to abort this mission?") )) {
         array_free(pclist);
         return;
      }

      /* Get the mission. */
      f = -1;
      for (int i=0; i<array_size(player_missions); i++) {
         for (int j=0; j<array_size(player_missions[i]->cargo); j++) {
            if (player_missions[i]->cargo[j] == pclist[pos].id) {
               f = i;
               break;
            }
         }
         if (f >= 0)
            break;
      }
      if (f < 0) {
         WARN(_("Cargo '%d' does not belong to any active mission."),
               pclist[pos].id);
         array_free( pclist );
         return;
      }
      misn = player_missions[f];

      /* We run the "abort" function if it's found. */
      ret = misn_tryRun( misn, "abort" );

      /* Now clean up mission. */
      if (ret != 2) {
         mission_cleanup( misn );
         mission_shift(pos);
      }

      /* Reset markers. */
      mission_sysMark();

      /* Reset claims. */
      claim_activateAll();

      /* Regenerate list. */
      mission_menu_genList( info_windows[ INFO_WIN_MISN ], 0 );
   }
   else
      /* Remove the cargo */
      pfleet_cargoRm( pclist[pos].commodity, pclist[pos].quantity, 1 );

   /* We reopen the menu to recreate the list now. */
   ship_update( info_windows[ INFO_WIN_SHIP ] );
   cargo_genList( wid );
   array_free( pclist );
}

/**
 * @brief Gets the window standings window dimensions.
 */
static void info_getDim( unsigned int wid, int *w, int *h, int *lw )
{
   /* Get the dimensions. */
   window_dimWindow( wid, w, h );
   *lw = *w-60-BUTTON_WIDTH-120;
}

/**
 * @brief Closes the faction stuff.
 */
static void standings_close( unsigned int wid, const char *str )
{
   (void) wid;
   (void) str;
   array_free(info_factions);
   info_factions = NULL;
}

static int factionsSort( const void *p1, const void *p2 )
{
   int f1, f2;
   double v1, v2;
   f1 = *(int*)p1;
   f2 = *(int*)p2;
   v1 = round(faction_getPlayer(f1));
   v2 = round(faction_getPlayer(f2));
   if (v1 < v2)
      return 1;
   else if (v1 > v2)
      return -1;
   return strcmp(faction_longname(f1), faction_longname(f2));
}
/**
 * @brief Displays the player's standings.
 */
static void info_openStandings( unsigned int wid )
{
   char **str;
   int w, h, lw;

   /* Get dimensions. */
   info_getDim( wid, &w, &h, &lw );

   /* On close. */
   window_onCleanup( wid, standings_close );

   /* Buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeMissions", _("Close"), info_close );

   /* Graphics. */
   window_addImage( wid, 0, 0, 0, 0, "imgLogo", NULL, 0 );

   /* Text. */
   window_addText( wid, lw+40, 0, (w-(lw+60)), 20, 1, "txtName",
         &gl_defFont, NULL, NULL );
   window_addText( wid, lw+40, 0, (w-(lw+60)), 20, 1, "txtStanding",
         &gl_defFont, NULL, NULL );
   window_addText( wid, lw+40, 0, (w-(lw+60)), 300, 0, "txtDescription",
         &gl_defFont, NULL, NULL );

   /* Gets the faction standings. */
   info_factions  = faction_getKnown();
   str            = malloc( sizeof(char*) * array_size(info_factions) );
   qsort( info_factions, array_size(info_factions), sizeof(int), factionsSort );

   /* Create list. */
   for (int i=0; i<array_size(info_factions); i++) {
      int m = round( faction_getPlayer( info_factions[i] ) );
      asprintf( &str[i], "%s   [ #%c%+d%%#0 ]",
            faction_longname( info_factions[i] ),
            faction_getColourChar( info_factions[i] ), m );
   }

   /* Display list. */
   window_addList( wid, 20, -40, lw, h-60, "lstStandings",
         str, array_size(info_factions), 0, standings_update, NULL );
   window_setFocus( wid, "lstStandings" );
}

/**
 * @brief Updates the standings menu.
 */
static void standings_update( unsigned int wid, const char *str )
{
   (void) str;
   int p, y;
   const glTexture *t;
   int w, h, lw, m, l;
   char buf[STRMAX];

   /* Get dimensions. */
   info_getDim( wid, &w, &h, &lw );

   /* Get faction. */
   p = toolkit_getListPos( wid, "lstStandings" );

   /* Render logo. */
   t = faction_logo( info_factions[p] );
   if (t != NULL) {
      int tw = t->w * (double)FACTION_LOGO_SM / MAX( t->w, t->h );
      int th = t->h * (double)FACTION_LOGO_SM / MAX( t->w, t->h );
      window_modifyImage( wid, "imgLogo", t, tw, th );
      y  = -40;
      window_moveWidget( wid, "imgLogo", lw+40 + (w-(lw+60)-tw)/2, y - (FACTION_LOGO_SM-th)/2 );
      y -= FACTION_LOGO_SM;
   }
   else {
      window_modifyImage( wid, "imgLogo", NULL, 0, 0 );
      y = -20;
   }

   /* Modify text. */
   y -= 20;
   m = round( faction_getPlayer( info_factions[p] ) );
   snprintf( buf, sizeof(buf), "#%c%+d%%#0   [ %s ]",
      faction_getColourChar( info_factions[p] ), m,
      faction_getStandingText( info_factions[p] ) );
   window_modifyText( wid, "txtName", faction_longname( info_factions[p] ) );
   window_moveWidget( wid, "txtName", lw+40, y );
   y -= 20;
   window_modifyText( wid, "txtStanding", buf );
   window_moveWidget( wid, "txtStanding", lw+40, y );
   y -= 30;
   l  = scnprintf( buf, sizeof(buf), "%s\n\n", faction_description( info_factions[p] ) );
   l += scnprintf( &buf[l], sizeof(buf)-l, _("You can have a maximum reputation of %.0f%% with this faction."), round(faction_reputationMax( info_factions[p] )) );
   window_modifyText( wid, "txtDescription", buf );
   window_moveWidget( wid, "txtDescription", lw+40, y );
}

/**
 * @brief Shows the player's active missions.
 *
 *    @param parent Unused.
 *    @param str Unused.
 */
static void info_openMissions( unsigned int wid )
{
   int w, h;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeMissions", _("Close"), info_close );
   window_addButtonKey( wid, -20, 40 + BUTTON_HEIGHT,
         BUTTON_WIDTH, BUTTON_HEIGHT, "btnAbortMission", _("Abort"),
         mission_menu_abort, SDLK_a );

   /* text */
   window_addText( wid, 300+40, -60,
         200, 40, 0, "txtSReward",
         &gl_smallFont, NULL, _("#nReward:#0") );
   window_addText( wid, 300+40, -80,
         200, 40, 0, "txtReward", &gl_smallFont, NULL, NULL );
   window_addText( wid, 300+40, -120,
         w - (300+40+40), h - BUTTON_HEIGHT - 120, 0,
         "txtDesc", &gl_smallFont, NULL, NULL );

   /* Put a map. */
   map_show( wid, 20, 20, 300, 260, 0.75, 0., 0. );

   /* list */
   mission_menu_genList(wid ,1);
}
/**
 * @brief Creates the current mission list for the mission menu.
 *    @param first 1 if it's the first time run.
 */
static void mission_menu_genList( unsigned int wid, int first )
{
   int j;
   char** misn_names;
   int w, h;

   if (!first)
      window_destroyWidget( wid, "lstMission" );

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* list */
   misn_names = malloc(sizeof(char*) * MAX(1, array_size(player_missions)));
   selectedMission = -1;
   j = 0;
   for (int i=0; i<array_size(player_missions); i++)
      if (player_missions[i]->id != 0)
         misn_names[j++] = (player_missions[i]->title != NULL) ?
               strdup(player_missions[i]->title) : NULL;

   if (j==0) { /* no missions */
      misn_names[j++] = strdup(_("No Missions"));
      window_modifyText( wid, "txtReward", _("None") );
      window_modifyText( wid, "txtDesc", _("You currently have no active missions.") );
      window_disableButton( wid, "btnAbortMission" );
      selectedMission = 0; /* misn_menu_update should do nothing. */
   }
   window_addList( wid, 20, -40,
         300, h-340,
         "lstMission", misn_names, j, selectedMission, mission_menu_update, NULL );
   window_setFocus( wid, "lstMission" );
}
/**
 * @brief Updates the mission menu mission information based on what's selected.
 *    @param str Unused.
 */
static void mission_menu_update( unsigned int wid, const char *str )
{
   (void) str;
   Mission* misn;
   const StarSystem *sys;
   int pos = toolkit_getListPos(wid, "lstMission" );

   if (pos < 0 || pos == selectedMission)
      return;

   /* Modify the text. */
   selectedMission = pos;
   misn = player_missions[selectedMission];
   window_modifyText( wid, "txtReward", misn->reward );
   window_modifyText( wid, "txtDesc", misn->desc );
   window_enableButton( wid, "btnAbortMission" );

   /* Select the system. */
   sys = mission_getSystemMarker( misn );
   if (sys != NULL)
      map_center( wid, sys->name );
}
/**
 * @brief Aborts a mission in the mission menu.
 *    @param str Unused.
 */
static void mission_menu_abort( unsigned int wid, const char *str )
{
   (void) str;
   int pos;
   Mission *misn;
   int ret;

   if (!dialogue_YesNo( _("Abort Mission"),
            _("Are you sure you want to abort this mission?") ))
      return;

   /* Get the mission. */
   pos = toolkit_getListPos(wid, "lstMission" );
   misn = player_missions[pos];

   /* We run the "abort" function if it's found. */
   ret = misn_tryRun( misn, "abort" );

   /* Now clean up mission. */
   if (ret != 2) {
      mission_cleanup( misn );
      mission_shift(pos);
   }

   /* Reset markers. */
   mission_sysMark();

   /* Reset claims. */
   claim_activateAll();

   /* Regenerate list. */
   mission_menu_genList(wid ,0);

   /* Regenerate bar if landed. */
   bar_regen();
}

/* amount of screen available for logs: -20 below button, -20 above button, -40 from top, -20 x2 between logs.*/
#define LOGSPACING (h - 120 - BUTTON_HEIGHT )

/**
 * @brief Updates the mission menu mission information based on what's selected.
 *    @param str Unused.
 */
static void shiplog_menu_update( unsigned int wid, const char *str )
{
   int regenerateEntries=0;
   int w, h;
   int logType, log;
   int nentries;
   char **logentries;

   if (!logWidgetsReady)
      return;

   /* This is called when something is selected.
    * If a new log type has been selected, need to regenerate the log lists.
    * If a new log has been selected, need to regenerate the entries. */
   if (strcmp(str, "lstLogEntries" ) != 0) {
      /* has selected a type of log or a log */
      window_dimWindow( wid, &w, &h );
      logWidgetsReady=0;

      logType = toolkit_getListPos( wid, "lstLogType" );
      log = toolkit_getListPos( wid, "lstLogs" );

      if (logType != selectedLogType) {
         /* new log type selected */
         selectedLogType = logType;
         window_destroyWidget( wid, "lstLogs" );
         logs = NULL;
         shiplog_listLogsOfType( info_getLogTypeFilter(selectedLogType), &nlogs, &logs, &logIDs, 1 );
         if (selectedLog >= nlogs)
            selectedLog = 0;
         window_addList( wid, 20, 60 + BUTTON_HEIGHT  + LOGSPACING / 2,
                         w-40, LOGSPACING / 4,
                         "lstLogs", logs, nlogs, 0, shiplog_menu_update, NULL );

         toolkit_setListPos( wid, "lstLogs", selectedLog );
         regenerateEntries=1;
      }
      if (regenerateEntries || selectedLog != log) {
         selectedLog = CLAMP( 0, nlogs-1, log );
         /* list log entries of selected log type */
         window_destroyWidget( wid, "lstLogEntries" );
         shiplog_listLog( logIDs[selectedLog], info_getLogTypeFilter(selectedLogType), &nentries, &logentries, 1 );
         window_addList( wid, 20, 40 + BUTTON_HEIGHT,
                         w-40, LOGSPACING / 2-20,
                         "lstLogEntries", logentries, nentries, 0, shiplog_menu_update, info_shiplogView );
         toolkit_setListPos( wid, "lstLogEntries", 0 );
         window_setFocus( wid, "lstLogEntries" );
      }
      logWidgetsReady=1;
   }
}

/**
 * @brief Translates a position in "lstLogType" to a shiplog "type" filter.
 */
static const char* info_getLogTypeFilter( int lstPos )
{
   if (lstPos < 1)
      return NULL; /* "All" */
   return logTypes[lstPos];
}

/**
 * @brief Generates the ship log information
 *    @param first 1 if it's the first time run.
 */
static void shiplog_menu_genList( unsigned int wid, int first )
{
   int w, h;
   int nentries;
   char **logentries;

   /* Needs 3 lists:
    * 1. List of log types (and All)
    * 2. List of logs of the selected type (and All)
    * 3. Listing of the selected log
    */
   if (!first) {
      window_destroyWidget( wid, "lstLogType" );
      window_destroyWidget( wid, "lstLogs" );
      logs = NULL;
      window_destroyWidget( wid, "lstLogEntries" );
   }
   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );

   /* list log types */
   shiplog_listTypes(&ntypes, &logTypes, 1);
   if ( selectedLogType >= ntypes )
      selectedLogType = 0;
   /* list logs of selected type */
   shiplog_listLogsOfType(info_getLogTypeFilter(selectedLogType), &nlogs, &logs, &logIDs, 1);
   if ( selectedLog >= nlogs )
      selectedLog = 0;
   /* list log entries of selected log */
   shiplog_listLog(logIDs[selectedLog], info_getLogTypeFilter(selectedLogType), &nentries, &logentries, 1);
   logWidgetsReady=0;
   window_addList( wid, 20, 80 + BUTTON_HEIGHT + 3*LOGSPACING/4 ,
                   w-40, LOGSPACING / 4,
         "lstLogType", logTypes, ntypes, 0, shiplog_menu_update, NULL );
   window_addList( wid, 20, 60 + BUTTON_HEIGHT + LOGSPACING / 2,
                   w-40, LOGSPACING / 4,
         "lstLogs", logs, nlogs, 0, shiplog_menu_update, NULL );
   window_addList( wid, 20, 40 + BUTTON_HEIGHT,
                   w-40, LOGSPACING / 2-20,
                   "lstLogEntries", logentries, nentries, 0, shiplog_menu_update, info_shiplogView );
   window_setFocus( wid, "lstLogEntries" );
   logWidgetsReady=1;
}

static void info_shiplogMenuDelete( unsigned int wid, const char *str )
{
   (void) str;
   char buf[STRMAX_SHORT];
   int ret, logid;

   if (logIDs[selectedLog] == LOG_ID_ALL) {
      dialogue_msg( "", _("You are currently viewing all logs in the selected log type. Please select a log title to delete.") );
      return;
   }

   snprintf( buf, sizeof(buf),
         _("This will delete ALL \"%s\" log entries. This operation cannot be undone. Are you sure?"),
         logs[selectedLog]);
   ret = dialogue_YesNoRaw( "", buf );
   if (!ret)
      return;
   /* There could be several logs of the same name, so make sure we get the correct one. */
   /* selectedLog-1 since not including the "All" */
   logid = shiplog_getIdOfLogOfType( info_getLogTypeFilter(selectedLogType), selectedLog-1 );
   if (logid >= 0)
      shiplog_delete( logid );
   selectedLog = 0;
   selectedLogType = 0;
   shiplog_menu_genList(wid, 0);
}

static void info_shiplogView( unsigned int wid, const char *str )
{
   char **logentries;
   int nentries;
   int pos;
   (void) str;

   pos = toolkit_getListPos( wid, "lstLogEntries" );
   if (pos < 0)
      return;
   shiplog_listLog(
         logIDs[selectedLog], info_getLogTypeFilter(selectedLogType), &nentries,
         &logentries, 1);

   if (pos < nentries)
      dialogue_msgRaw( _("Log message"), logentries[pos] );

   for (int i=0; i<nentries; i++)
      free( logentries[i] );
   free( logentries );
}

/**
 * @brief Asks the player for an entry to add to the log
 *
 * @param wid Window widget
 * @param str Button widget name
 */
static void info_shiplogAdd( unsigned int wid, const char *str )
{
   char *tmp;
   int logType, log;
   int logid;
   (void) str;

   logType = toolkit_getListPos( wid, "lstLogType" );
   log = toolkit_getListPos( wid, "lstLogs" );
   if ( log < 0 || logIDs[log] == LOG_ID_ALL ) {
      tmp = dialogue_inputRaw( _("Add a log entry"), 0, 4096, _("Add an entry to your diary:") );
      if ( ( tmp != NULL ) && ( strlen(tmp) > 0 ) ) {
         if ( shiplog_getID( "Diary" ) == -1 )
              shiplog_create( "Diary", _("Your Diary"), "Diary", 0, 0 );
         shiplog_append( "Diary", tmp );
         free( tmp );
      }
   } else {
      tmp = dialogue_input( _("Add a log entry"), 0, 4096, _("Add an entry to the log titled '%s':"), logs[log] );
      if ( ( tmp != NULL ) && ( strlen(tmp) > 0 ) ) {
         logid = shiplog_getIdOfLogOfType( info_getLogTypeFilter(logType), log-1 );
         if ( logid >= 0 )
            shiplog_appendByID( logid, tmp );
         else
            dialogue_msgRaw( _("Cannot add log"), _("Cannot find this log!  Something went wrong here!") );
         free( tmp );
      }
   }
   shiplog_menu_genList( wid, 0 );

}

/**
 * @brief Shows the player's ship log.
 *
 *    @param wid Window widget
 */
static void info_openShipLog( unsigned int wid )
{
   int w, h, texth;
   /* re-initialise the statics */
   selectedLog = 0;
   selectedLogType = 0;

   /* Get the dimensions. */
   window_dimWindow( wid, &w, &h );
   /* buttons */
   window_addButton( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "closeShipLog", _("Close"), info_close );
   window_addButton( wid, -20 - 1*(20+BUTTON_WIDTH), 20,
         BUTTON_WIDTH, BUTTON_HEIGHT, "btnDeleteLog", _("Delete"),
         info_shiplogMenuDelete );
   window_addButton( wid, -20 - 2*(20+BUTTON_WIDTH), 20, BUTTON_WIDTH,
         BUTTON_HEIGHT, "btnViewLog", _("View Entry"),
         info_shiplogView );
   window_addButton( wid, -20 - 3*(20+BUTTON_WIDTH), 20, BUTTON_WIDTH,
         BUTTON_HEIGHT, "btnAddLog", _("Add Entry"),
         info_shiplogAdd );
   /* Description text */
   texth = gl_printHeightRaw( &gl_smallFont, w, "Select log type" );
   window_addText( wid, 20, 80 + BUTTON_HEIGHT + LOGSPACING,
                   w - 40, texth, 0,
                   "logDesc1", &gl_smallFont, NULL, _("Select log type:") );

   window_addText( wid, 20, 60 + BUTTON_HEIGHT + 3* LOGSPACING / 4,
                   w - 40, texth, 0,
                   "logDesc2", &gl_smallFont, NULL, _("Select log title:") );

   window_addText( wid, 20, 25 + BUTTON_HEIGHT + LOGSPACING / 2,
                   w - 40, texth, 0,
                   "logDesc3", &gl_smallFont, NULL, _("Log entries:") );

#undef LOGSPACING
   /* list */
   shiplog_menu_genList(wid ,1);
}

/**
 * @brief Handles tab window changes.
 */
static void info_changeTab( unsigned int wid, const char *str, int old, int new )
{
   (void) wid;
   (void) str;
   (void) old;
   const char *hookname;
   switch (new) {
      case INFO_WIN_MAIN:  hookname = "info_main";    break;
      case INFO_WIN_SHIP:  hookname = "info_ship";    break;
      case INFO_WIN_WEAP:  hookname = "info_weapons"; break;
      case INFO_WIN_CARGO: hookname = "info_cargo";   break;
      case INFO_WIN_MISN:  hookname = "info_mission"; break;
      case INFO_WIN_STAND: hookname = "info_standing";break;
      case INFO_WIN_SHIPLOG:hookname= "info_shiplog"; break;
      default: ERR( _("Invalid info tab ID: %d"), new );
   }
   hooks_run( hookname );
}
