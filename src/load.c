/*
 * See Licensing and Copyright notice in naev.h
 */
/**
 * @file load.c
 *
 * @brief Contains stuff to load a pilot or look up information about it.
 */

/** @cond */
#include "physfs.h"

#include "naev.h"
/** @endcond */

#include "load.h"

#include "array.h"
#include "dialogue.h"
#include "economy.h"
#include "event.h"
#include "faction.h"
#include "difficulty.h"
#include "gui.h"
#include "hook.h"
#include "land.h"
#include "log.h"
#include "menu.h"
#include "mission.h"
#include "news.h"
#include "ndata.h"
#include "nlua_var.h"
#include "nstring.h"
#include "nxml.h"
#include "outfit.h"
#include "player.h"
#include "save.h"
#include "shiplog.h"
#include "start.h"
#include "space.h"
#include "toolkit.h"
#include "unidiff.h"

#define LOAD_WIDTH      600 /**< Load window width. */
#define LOAD_HEIGHT     530 /**< Load window height. */

#define BUTTON_WIDTH    120 /**< Button width. */
#define BUTTON_HEIGHT   30 /**< Button height. */

/**
 * @brief Struct containing a file's name and stat structure.
 */
typedef struct filedata {
   char *name;
   PHYSFS_Stat stat;
} filedata_t;

static nsave_t *load_saves = NULL; /**< Array of saves */
static char **player_names = NULL; /**< Array of player names */
static int old_saves_detected = 0, player_warned = 0;
static char *selected_player = NULL;
extern int save_loaded; /**< From save.c */

/*
 * Prototypes.
 */
/* externs */
/* player.c */
extern Spob* player_load( xmlNodePtr parent ); /**< Loads player related stuff. */
/* event.c */
extern int events_loadActive( xmlNodePtr parent );
/* news.c */
extern int news_loadArticles( xmlNodePtr parent );
/* nlua_var.c */
extern int var_load( xmlNodePtr parent ); /**< Loads mission variables. */
/* faction.c */
extern int pfaction_load( xmlNodePtr parent ); /**< Loads faction data. */
/* hook.c */
extern int hook_load( xmlNodePtr parent ); /**< Loads hooks. */
/* space.c */
extern int space_sysLoad( xmlNodePtr parent ); /**< Loads the space stuff. */
/* economy.c */
extern int economy_sysLoad( xmlNodePtr parent ); /**< Loads the economy stuff. */
/* unidiff.c */
extern int diff_load( xmlNodePtr parent ); /**< Loads the universe diffs. */
/* static */
static void load_menu_update( unsigned int wid, const char *str );
static void load_menu_close( unsigned int wdw, const char *str );
static void load_menu_load( unsigned int wdw, const char *str );
static void load_menu_delete( unsigned int wdw, const char *str );
static void load_menu_snapshots( unsigned int wdw, const char *str );
static void load_snapshot_menu_update( unsigned int wid, const char *str );
static void load_snapshot_menu_close( unsigned int wdw, const char *str );
static void load_snapshot_menu_load( unsigned int wdw, const char *str );
static void load_snapshot_menu_delete( unsigned int wdw, const char *str );
static void load_snapshot_menu_save( unsigned int wdw, const char *str );
static void display_save_info( unsigned int wid, const nsave_t *ns );
static void move_old_save( const char *path, const char *fname, const char *ext, const char *new_name );
static int load_load( nsave_t *save, const char *path );
static int load_game( nsave_t *ns );
static int load_gameInternal( const char* file, const char* version );
static int load_enumerateCallback( void* data, const char* origdir, const char* fname );
static int load_enumeratePlayerNamesCallback( void* data, const char* origdir, const char* fname );
static int load_sortCompare( const void *p1, const void *p2 );
static xmlDocPtr load_xml_parsePhysFS( const char* filename );

/**
 * @brief Loads an individual save.
 * @param[out] save Structure to populate.
 * @param path PhysicsFS path (i.e., relative path starting with "saves/").
 */
static int load_load( nsave_t *save, const char *path )
{
   xmlDocPtr doc;
   xmlNodePtr root, parent, node, cur;
   int cycles, periods, seconds;

   memset( save, 0, sizeof(nsave_t) );

   /* Load the XML. */
   doc = load_xml_parsePhysFS( path );
   if (doc == NULL) {
      WARN( _("Unable to parse save path '%s'."), path);
      return -1;
   }
   root = doc->xmlChildrenNode; /* base node */
   if (root == NULL) {
      WARN( _("Unable to get child node of save '%s'."), path);
      xmlFreeDoc(doc);
      return -1;
   }

   /* Save path. */
   save->path = strdup(path);

   /* Iterate inside the naev_save. */
   parent = root->xmlChildrenNode;
   do {
      xml_onlyNodes(parent);

      /* Info. */
      if (xml_isNode(parent, "version")) {
         node = parent->xmlChildrenNode;
         do {
            xmlr_strd(node, "naev", save->version);
            xmlr_strd(node, "data", save->data);
         } while (xml_nextNode(node));
         continue;
      }

      else if (xml_isNode(parent, "player")) {
         /* Get name. */
         xmlr_attr_strd(parent, "name", save->name);
         /* Parse rest. */
         node = parent->xmlChildrenNode;
         do {
            xml_onlyNodes(node);

            /* Player info. */
            xmlr_strd(node, "location", save->spob);
            xmlr_ulong(node, "credits", save->credits);
            xmlr_strd(node, "chapter", save->chapter);
            xmlr_strd(node, "difficulty", save->difficulty);

            /* Time. */
            if (xml_isNode(node, "time")) {
               cur = node->xmlChildrenNode;
               cycles = periods = seconds = 0;
               do {
                  xmlr_int(cur, "SCU", cycles);
                  xmlr_int(cur, "STP", periods);
                  xmlr_int(cur, "STU", seconds);
               } while (xml_nextNode(cur));
               save->date = ntime_create( cycles, periods, seconds );
               continue;
            }

            /* Ship info. */
            if (xml_isNode(node, "ship")) {
               xmlr_attr_strd(node, "name", save->shipname);
               xmlr_attr_strd(node, "model", save->shipmodel);
               continue;
            }
         } while (xml_nextNode(node));
         continue;
      }
   } while (xml_nextNode(parent));

   /* Defaults. */
   if (save->chapter==NULL)
      save->chapter = strdup( start_chapter() );

   /* Clean up. */
   xmlFreeDoc(doc);

   return 0;
}

/**
 * @brief Loads or refreshes player names.
 */
int load_refreshPlayerNames (void)
{
   filedata_t *dirs;
   int n;

   if (player_names != NULL)
      load_freePlayerNames();

   dirs = array_create( filedata_t );
   PHYSFS_enumerate( "saves", load_enumeratePlayerNamesCallback, &dirs );

   qsort( dirs, array_size(dirs), sizeof(filedata_t), load_sortCompare );

   n = array_size(dirs);
   player_names = array_create_size( char*, n );
   for (int i=0; i<n; i++)
      array_grow( &player_names ) = strdup( dirs[i].name );

   /* Clean up memory. */
   for (int i=0; i<array_size(dirs); i++)
      free( dirs[i].name );
   array_free( dirs );

   return 0;
}

/**
 * @brief Loads or refreshes saved games for the player.
 *    @param name Player's name.
 */
int load_refresh ( const char *name )
{
   char buf[PATH_MAX];
   filedata_t *files;
   int ok;
   nsave_t *ns;

   if (load_saves != NULL)
      load_free();

   /* load the saves */
   files = array_create( filedata_t );
   snprintf( buf, sizeof(buf), "saves/%s", name );
   PHYSFS_enumerate( buf, load_enumerateCallback, &files );
   qsort( files, array_size(files), sizeof(filedata_t), load_sortCompare );

   if (array_size(files) == 0) {
      array_free( files );
      return 0;
   }

   /* Allocate and parse. */
   ok = 0;
   ns = NULL;
   load_saves = array_create_size( nsave_t, array_size(files) );
   for (int i=0; i<array_size(files); i++) {
      if (!ok)
         ns = &array_grow( &load_saves );
      snprintf( buf, sizeof(buf), "saves/%s/%s", name, files[i].name );
      ok = load_load( ns, buf );
      ns->save_name = strdup( files[i].name );
      ns->save_name[ strlen(ns->save_name)-3 ] = '\0';
      ns->modtime = files[i].stat.modtime;
   }

   /* If the save was invalid, array is 1 member too large. */
   if (ok)
      array_resize( &load_saves, array_size(load_saves)-1 );

   /* Clean up memory. */
   for (int i=0; i<array_size(files); i++)
      free( files[i].name );
   array_free( files );

   return 0;
}

/**
 * @brief The PHYSFS_EnumerateCallback for load_refresh
 */
static int load_enumerateCallback( void* data, const char* origdir, const char* fname )
{
   char *path;
   const char *fmt;
   size_t dir_len, name_len;
   filedata_t *tmp;
   PHYSFS_Stat stat;

   dir_len = strlen( origdir );
   name_len = strlen( fname );

   /* no save extension? */
   if (name_len < 4 || strcmp( &fname[name_len-3], ".ns" ))
      return PHYSFS_ENUM_OK;

   fmt = dir_len && origdir[dir_len-1]=='/' ? "%s%s" : "%s/%s";
   asprintf( &path, fmt, origdir, fname );
   if (!PHYSFS_stat( path, &stat ))
      WARN( _("PhysicsFS: Cannot stat %s: %s"), path,
            _(PHYSFS_getErrorByCode( PHYSFS_getLastErrorCode() ) ) );
   else if (stat.filetype == PHYSFS_FILETYPE_REGULAR) {
      tmp = &array_grow( (filedata_t**)data );
      tmp->name = strdup( fname );
      tmp->stat = stat;
   }

   free( path );
   return PHYSFS_ENUM_OK;
}

/**
 * @brief The PHYSFS_EnumerateCallback for load_refreshPlayerNames
 */
static int load_enumeratePlayerNamesCallback( void* data, const char* origdir, const char* fname )
{
   char *path, *backup_path;
   const char *fmt;
   size_t dir_len, name_len;
   filedata_t *tmp;
   PHYSFS_Stat stat;

   dir_len = strlen( origdir );
   name_len = strlen( fname );

   fmt = dir_len && origdir[dir_len-1]=='/' ? "%s%s" : "%s/%s";
   asprintf( &path, fmt, origdir, fname );
   if (!PHYSFS_stat( path, &stat ))
      WARN( _("PhysicsFS: Cannot stat %s: %s"), path,
            _(PHYSFS_getErrorByCode( PHYSFS_getLastErrorCode() ) ) );
   /* TODO remove this sometime in the future. Maybe 0.12.0 or 0.13.0? */
   else if (stat.filetype == PHYSFS_FILETYPE_REGULAR) {
      if ((name_len < 4 || strcmp( &fname[name_len-3], ".ns" )) && (name_len < 11 || strcmp( &fname[name_len-10], ".ns.backup" ))) {
         free( path );
         return PHYSFS_ENUM_OK;
      }
      if (!PHYSFS_exists( "saves-pre-0.10.0" ))
         PHYSFS_mkdir( "saves-pre-0.10.0" );
      asprintf( &backup_path, "saves-pre-0.10.0/%s", fname );
      if (!ndata_copyIfExists( path, backup_path ))
         old_saves_detected = 1;
      free( backup_path );
      move_old_save( path, fname, ".ns", "autosave.ns" );
      move_old_save( path, fname, ".ns.backup", "backup.ns" );
   }
   else if (stat.filetype == PHYSFS_FILETYPE_DIRECTORY) {
      load_refresh( fname );
      if (array_size( load_getList() ) == 0) {
         free( path );
         return PHYSFS_ENUM_OK;
      }
      tmp = &array_grow( (filedata_t**)data );
      tmp->name = strdup( fname );
      tmp->stat = stat;
      /* Fake modtime based on the last save's modtime */
      tmp->stat.modtime = load_saves[0].modtime;
   }

   free( path );
   return PHYSFS_ENUM_OK;
}

/**
 * @brief qsort compare function for files.
 */
static int load_sortCompare( const void *p1, const void *p2 )
{
   const filedata_t *f1, *f2;

   f1 = (const filedata_t*) p1;
   f2 = (const filedata_t*) p2;

   if (f1->stat.modtime > f2->stat.modtime)
      return -1;
   else if (f1->stat.modtime < f2->stat.modtime)
      return +1;

   return strcmp( f1->name, f2->name );
}

/**
 * @brief Frees loaded save stuff.
 */
void load_free (void)
{
   for (int i=0; i<array_size(load_saves); i++) {
      nsave_t *ns = &load_saves[i];
      free(ns->save_name);
      free(ns->path);
      free(ns->name);
      free(ns->version);
      free(ns->data);
      free(ns->spob);
      free(ns->chapter);
      free(ns->difficulty);
      free(ns->shipname);
      free(ns->shipmodel);
   }
   array_free( load_saves );
   load_saves = NULL;
}

/**
 * @brief Frees loaded player names.
 */
void load_freePlayerNames (void)
{
   for (int i=0; i<array_size(player_names); i++)
      free(player_names[i]);
   array_free( player_names );
   player_names = NULL;
}

/**
 * @brief Frees selected player name.
 */
void load_freeSelectedPlayerName (void)
{
   free( selected_player );
   selected_player = NULL;
}

/**
 * @brief Gets the array (array.h) of player names.
 */
const char **load_getPlayerNames (void)
{
   return (const char **) player_names;
}

/**
 * @brief Gets the array (array.h) of loaded saves.
 */
const nsave_t *load_getList (void)
{
   return load_saves;
}

/**
 * @brief Opens the load game menu.
 */
void load_loadGameMenu (void)
{
   unsigned int wid;
   char **names;
   int n;
   int pos = 0;

   /* window */
   wid = window_create( "wdwLoadGameMenu", _("Load Pilot"), -1, -1, LOAD_WIDTH, LOAD_HEIGHT );
   window_setAccept( wid, load_menu_load );
   window_setCancel( wid, load_menu_close );

   load_refreshPlayerNames();

   n = array_size( player_names );
   if (n > 0) {
      names = malloc( sizeof(char*)*n );
      for (int i=0; i<n; i++) {
         names[i] = strdup( player_names[i] );
         if (selected_player != NULL && !strcmp( names[i], selected_player ))
            pos = i;
      }
   }
   /* case there are no players */
   else {
      names = malloc(sizeof(char*));
      names[0] = strdup(_("None"));
      n = 1;
   }

   /* Player text. */
   window_addText( wid, -20, -40, BUTTON_WIDTH*2+20, LOAD_HEIGHT-40-20-2*(BUTTON_HEIGHT+20),
         0, "txtPilot", &gl_smallFont, NULL, NULL );

   window_addList( wid, 20, -40,
         LOAD_WIDTH-BUTTON_WIDTH*2-80, LOAD_HEIGHT-110,
         "lstNames", names, n, pos, load_menu_update, load_menu_load );

   /* Buttons */
   window_addButtonKey( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnBack", _("Back"), load_menu_close, SDLK_b );
   window_addButtonKey( wid, -20-BUTTON_WIDTH-20, 20 + BUTTON_HEIGHT+15, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnSnapshots", _("Snapshots"), load_menu_snapshots, SDLK_s );
   window_addButtonKey( wid, -20, 20 + BUTTON_HEIGHT+15, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnLoad", _("Load"), load_menu_load, SDLK_l );
   window_addButton( wid, 20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnDelete", _("Delete"), load_menu_delete );

   if (old_saves_detected && !player_warned) {
      /* TODO we should print the full OS path if possible here. */
      dialogue_alert( _("Naev has detected saves in pre-0.10.0 format, and has automatically migrated them to the new format. Old saves have been backed up at '%s'."), "saves-pre-0.10.0");
      player_warned = 1;
   }
}

/**
 * @brief Opens the load snapshot menu.
 *    @param name Player's name.
 */
void load_loadSnapshotMenu ( const char *name )
{
   unsigned int wid;
   char **names;
   nsave_t *ns;
   int n, can_save;
   char *player_name = strdup( name );

   /* window */
   wid = window_create( "wdwLoadSnapshotMenu", _("Load Snapshot"), -1, -1, LOAD_WIDTH, LOAD_HEIGHT );
   window_setAccept( wid, load_snapshot_menu_load );
   window_setCancel( wid, load_snapshot_menu_close );

   free(selected_player);
   selected_player = strdup( player_name );

   /* Load loads. */
   load_refresh( player_name );

   free( player_name );

   /* load the saves */
   n = array_size( load_saves );
   if (n > 0) {
      names = malloc( sizeof(char*)*n );
      for (int i=0; i<n; i++) {
         ns       = &load_saves[i];
         names[i] = strdup( ns->save_name );
      }
   }
   /* case there are no files */
   else {
      names = malloc(sizeof(char*));
      names[0] = strdup(_("None"));
      n     = 1;
   }

   /* Player text. */
   window_addText( wid, -20, -40, BUTTON_WIDTH*2+20, LOAD_HEIGHT-40-20-2*(BUTTON_HEIGHT+20),
         0, "txtPilot", &gl_smallFont, NULL, NULL );

   window_addList( wid, 20, -40,
         LOAD_WIDTH-BUTTON_WIDTH*2-80, LOAD_HEIGHT-110,
         "lstSaves", names, n, 0, load_snapshot_menu_update, load_snapshot_menu_load );

   /* Buttons */
   window_addButtonKey( wid, -20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnBack", _("Back"), load_snapshot_menu_close, SDLK_b );
   window_addButtonKey( wid, -20-BUTTON_WIDTH-20, 20 + BUTTON_HEIGHT+15, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnSave", _("Save"), load_snapshot_menu_save, SDLK_s );
   window_addButtonKey( wid, -20, 20 + BUTTON_HEIGHT+15, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnLoad", _("Load"), load_snapshot_menu_load, SDLK_l );
   window_addButton( wid, 20, 20, BUTTON_WIDTH, BUTTON_HEIGHT,
         "btnDelete", _("Delete"), load_snapshot_menu_delete );

   if (window_exists( "wdwLoadGameMenu" ))
      window_disableButton( wid, "btnSave" );
   else {
      can_save = landed && !player_isFlag(PLAYER_NOSAVE);
      if (!can_save)
         window_disableButton( wid, "btnSave" );
   }
}

/**
 * @brief Opens the load snapshot menu.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_menu_snapshots( unsigned int wdw, const char *str )
{
   (void) str;
   int pos;
   const char *name;

   pos = toolkit_getListPos( wdw, "lstNames" );
   name = toolkit_getList( wdw, "lstNames" );
   if (strcmp(name,_("None")) == 0)
      return;
   load_loadSnapshotMenu( player_names[pos] );
}

/**
 * @brief Creates new custom snapshot.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_snapshot_menu_save( unsigned int wdw, const char *str )
{
   char *save_name = dialogue_input( _("Save game"), 1, 60, _("Please give the new snapshot a name:") );
   if (save_name == NULL)
      return;
   char path[PATH_MAX];
   snprintf(path, sizeof(path), "saves/%s/%s.ns", player.name, save_name);
   if (PHYSFS_exists( path )) {
      int r = dialogue_YesNo(_("Overwrite"),
         _("You already have a snapshot named '%s'. Overwrite?"), save_name);
      if (r==0) {
         load_snapshot_menu_save( wdw, str );
         return;
      }
   }
   if (save_all_with_name(save_name) < 0)
      dialogue_alert( _("Failed to save the game! You should exit and check the log to see what happened and then file a bug report!") );
   else {
      load_snapshot_menu_close( wdw, str );
      load_loadSnapshotMenu( player.name );
   }
}

/**
 * @brief Closes the load game menu.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_menu_close( unsigned int wdw, const char *str )
{
   (void)str;
   window_destroy( wdw );
}

/**
 * @brief Closes the load snapshot menu.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_snapshot_menu_close( unsigned int wdw, const char *str )
{
   (void)str;
   window_destroy( wdw );
}

/**
* @brief Displays Naev save info.
*    @param wid Widget for displaying save info.
*    @param ns Naev save.
*/
static void display_save_info( unsigned int wid, const nsave_t *ns )
{
   char buf[STRMAX_SHORT], credits[ECON_CRED_STRLEN], date[64], difficulty[STRMAX_SHORT];
   size_t l = 0;

   if (ns->difficulty == NULL) {
      const Difficulty *d = difficulty_cur();
      snprintf( difficulty, sizeof(difficulty), _("%s (options)"), _(d->name) );
   }
   else
      snprintf( difficulty, sizeof(difficulty), _("%s (this save)"), _(ns->difficulty) );

   credits2str( credits, ns->credits, 2 );
   ntime_prettyBuf( date, sizeof(date), ns->date, 2 );
   l += scnprintf( &buf[l], sizeof(buf)-l, "#n%s", _("Name:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->name );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Version:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->version );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Difficulty:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", difficulty );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Date:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", date );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Chapter:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->chapter );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Spob:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->spob );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Credits:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", credits );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Ship Name:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->shipname );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#n%s", _("Ship Model:") );
   l += scnprintf( &buf[l], sizeof(buf)-l, "\n#0   %s", ns->shipmodel );
   window_modifyText( wid, "txtPilot", buf );
}

/**
* @brief Moves old Naev saves to subdirectories.
*    @param path Path to old file.
*    @param fname Old filename.
*    @param ext Extension of file to move.
*    @param new_name Name for file in subdirectory.
*/
static void move_old_save( const char *path, const char *fname, const char *ext, const char *new_name )
{
   size_t name_len = strlen(fname);
   size_t ext_len = strlen(ext);
   if (name_len >= ext_len + 1 && !strcmp( &fname[name_len - ext_len], ext )) {
      char *dirname = strdup( fname );
      dirname[name_len - ext_len] = '\0';
      char *new_path;
      asprintf( &new_path, "saves/%s", dirname );
      if (!PHYSFS_exists( new_path ))
         PHYSFS_mkdir( new_path );
      free( new_path );
      asprintf( &new_path, "saves/%s/%s", dirname, new_name );
      if (!ndata_copyIfExists( path, new_path ))
         if (!PHYSFS_delete( path ))
            dialogue_alert( _("Unable to delete %s"), path );
      free( new_path );
      free( dirname );
   }
}

/**
 * @brief Updates the load menu.
 *    @param wid Widget triggering function.
 *    @param str Unused.
 */
static void load_menu_update( unsigned int wid, const char *str )
{
   (void) str;
   int pos;
   char *player_name;
   const nsave_t *ns;
   const char *save;

   /* Make sure list is ok. */
   save = toolkit_getList( wid, "lstNames" );
   if (strcmp(save,_("None")) == 0)
      return;

   /* Get position. */
   pos = toolkit_getListPos( wid, "lstNames" );
   player_name = player_names[pos];

   load_refresh( player_name );
   ns = &load_getList()[0];

   display_save_info( wid, ns );
}

/**
 * @brief Updates the load snapshot menu.
 *    @param wid Widget triggering function.
 *    @param str Unused.
 */
static void load_snapshot_menu_update( unsigned int wid, const char *str )
{
   (void) str;
   int pos;
   nsave_t *ns;
   const char *save;

   /* Make sure list is ok. */
   save = toolkit_getList( wid, "lstSaves" );
   if (strcmp(save,_("None")) == 0)
      return;

   /* Get position. */
   pos = toolkit_getListPos( wid, "lstSaves" );
   ns  = &load_saves[pos];

   display_save_info( wid, ns );
}

/**
 * @brief Loads a new game.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_menu_load( unsigned int wdw, const char *str )
{
   (void) str;
   const char *save;
   int diff;
   unsigned int wid;

   wid = window_get( "wdwLoadGameMenu" );
   save = toolkit_getList( wid, "lstNames" );

   if (strcmp(save,_("None")) == 0 || array_size(load_saves) == 0)
      return;

   /* Check version. */
   diff = naev_versionCompare( load_saves[0].version );
   if (ABS(diff) >= 2) {
      if (!dialogue_YesNo( _("Save game version mismatch"),
            _("Save game '%s' version does not match Naev version:\n"
            "   Save version: #r%s#0\n"
            "   Naev version: %s\n"
            "Are you sure you want to load this game? It may lose data."),
            save, load_saves[0].version, VERSION ))
         return;
   }

   /* Close menus before loading for proper rendering. */
   load_menu_close(wdw, NULL);

   /* Close the main menu. */
   menu_main_close();

   /* Try to load the game. */
   if (load_game( &load_saves[0] )) {
      /* Failed so reopen both. */
      menu_main();
      load_loadGameMenu();
   }
}

/**
 * @brief Loads a new game.
 *    @param wdw Window triggering function.
 *    @param str Unused.
 */
static void load_snapshot_menu_load( unsigned int wdw, const char *str )
{
   (void) str;
   const char *save;
   int wid, pos;
   int diff;

   wid = window_get( "wdwLoadSnapshotMenu" );
   save = toolkit_getList( wid, "lstSaves" );

   if (strcmp(save,_("None")) == 0)
      return;

   pos = toolkit_getListPos( wid, "lstSaves" );

   /* Check version. */
   diff = naev_versionCompare( load_saves[pos].version );
   if (ABS(diff) >= 2) {
      if (!dialogue_YesNo( _("Save game version mismatch"),
            _("Save game '%s' version does not match Naev version:\n"
            "   Save version: #r%s#0\n"
            "   Naev version: %s\n"
            "Are you sure you want to load this game? It may lose data."),
            save, load_saves[pos].version, VERSION ))
         return;
   }

   /* Close menus before loading for proper rendering. */
   load_snapshot_menu_close(wdw, NULL);

   if (window_exists( "wdwLoadGameMenu" )) {
      /* Close the main and the load menu. */
      load_menu_close( window_get( "wdwLoadGameMenu" ), NULL );
      menu_main_close();
   }
   else {
      if (landed)
         land_cleanup();
      menu_small_close();
   }

   /* Try to load the game. */
   if (load_game( &load_saves[pos] )) {
      /* Failed so reopen both. */
      /* TODO how to handle failure here? It can happen at many different points now. */
      /*menu_main();
      load_loadGameMenu();*/
   }
}

static void load_menu_delete( unsigned int wdw, const char *str )
{
   const char *name;
   unsigned int wid;
   int n;
   char path[PATH_MAX];

   wid = window_get( "wdwLoadGameMenu" );
   name = toolkit_getList( wid, "lstNames" );

   if (strcmp(name,"None") == 0)
      return;

   if (dialogue_YesNo( _("Permanently Delete?"),
      _("Are you sure you want to permanently delete '%s'?"), name) == 0)
      return;

   /* Remove it. */
   n = array_size( load_saves );
   for (int i = 0; i < n; i++)
      if (!PHYSFS_delete( load_saves[i].path ))
         dialogue_alert( _("Unable to delete %s"), load_saves[i].path );
   snprintf(path, sizeof(path), "saves/%s", name);
   if (!PHYSFS_delete( path ))
      dialogue_alert( _("Unable to delete '%s' directory"), name );

   /* need to reload the menu */
   load_menu_close( wdw, str );
   load_loadGameMenu();
}

/**
 * @brief Deletes an old game.
 *    @param wdw Window to delete.
 *    @param str Unused.
 */
static void load_snapshot_menu_delete( unsigned int wdw, const char *str )
{
   const char *save;
   unsigned int wid;
   int pos;

   wid = window_get( "wdwLoadSnapshotMenu" );
   save = toolkit_getList( wid, "lstSaves" );

   if (strcmp(save,"None") == 0)
      return;

   if (dialogue_YesNo( _("Permanently Delete?"),
      _("Are you sure you want to permanently delete '%s'?"), save) == 0)
      return;

   /* Remove it. */
   pos = toolkit_getListPos( wid, "lstSaves" );
   PHYSFS_delete( load_saves[pos].path );

   /* need to reload the menu */
   load_snapshot_menu_close( wdw, str );
   if (window_exists( "wdwLoadGameMenu" )) {
      wid = window_get( "wdwLoadGameMenu" );
      load_menu_close( wid, str );
      load_loadGameMenu();
   }
   load_loadSnapshotMenu( selected_player );
}

static void load_compatSlots (void)
{
   /* Vars for loading old saves. */
   char **sships;
   glTexture **tships;
   int nships;
   Pilot *ship;

   nships = player_nships();
   sships = malloc(nships * sizeof(char*));
   tships = malloc(nships * sizeof(glTexture*));
   nships = player_ships( sships, tships );
   ship   = player.p;
   for (int i=-1; i<nships; i++) {
      if (i >= 0)
         ship = player_getShip( sships[i] );
      /* Remove all outfits. */
      for (int j=0; j<array_size(ship->outfits); j++) {
         ShipOutfitSlot *sslot;

         if (ship->outfits[j]->outfit != NULL) {
            player_addOutfit( ship->outfits[j]->outfit, 1 );
            pilot_rmOutfitRaw( ship, ship->outfits[j] );
         }

         /* Add default outfit. */
         sslot = ship->outfits[j]->sslot;
         if (sslot->data != NULL)
            pilot_addOutfitRaw( ship, sslot->data, ship->outfits[j] );
      }

      pilot_calcStats( ship );
   }

   /* Clean up. */
   for (int i=0; i<nships; i++)
      free(sships[i]);
   free(sships);
   free(tships);
}

/**
 * @brief Loads the diffs from game file.
 *
 *    @param file PhysicsFS path (i.e., relative path starting with "saves/").
 *    @return 0 on success.
 */
int load_gameDiff( const char* file )
{
   xmlNodePtr node;
   xmlDocPtr doc;

   /* Make sure it exists. */
   if (!PHYSFS_exists( file )) {
      dialogue_alert( _("Saved game file seems to have been deleted.") );
      return -1;
   }

   /* Load the XML. */
   doc = load_xml_parsePhysFS( file );
   if (doc == NULL)
      goto err;
   node  = doc->xmlChildrenNode; /* base node */
   if (node == NULL)
      goto err_doc;

   /* Diffs should be cleared automatically first. */
   diff_load(node);

   /* Free. */
   xmlFreeDoc(doc);

   return 0;

err_doc:
   xmlFreeDoc(doc);
err:
   WARN( _("Saved game '%s' invalid!"), file);
   return -1;
}

/**
 * @brief Loads the game from a file.
 *
 *    @param file PhysicsFS path (i.e., relative path starting with "saves/").
 *    @return 0 on success
 */
int load_gameFile( const char *file )
{
   return load_gameInternal( file, naev_version(0) );
}

/**
 * @brief Actually loads a new game based on save structure.
 *
 *    @param ns Save game to load.
 *    @return 0 on success.
 */
static int load_game( nsave_t *ns )
{
   return load_gameInternal( ns->path, ns->version );
}

/**
 * @brief Actually loads a new game.
 *
 *    @param file PhysicsFS path (i.e., relative path starting with "saves/").
 *    @param version Version string of game to load.
 *    @return 0 on success.
 */
static int load_gameInternal( const char* file, const char* version )
{
   xmlNodePtr node;
   xmlDocPtr doc;
   Spob *pnt;
   int version_diff = (version!=NULL) ? naev_versionCompare(version) : 0;

   /* Make sure it exists. */
   if (!PHYSFS_exists( file )) {
      dialogue_alert( _("Saved game file seems to have been deleted.") );
      return -1;
   }

   /* Load the XML. */
   doc = load_xml_parsePhysFS( file );
   if (doc == NULL)
      goto err;
   node  = doc->xmlChildrenNode; /* base node */
   if (node == NULL)
      goto err_doc;

   /* Clean up possible stuff that should be cleaned. */
   unidiff_universeDefer( 1 );
   player_cleanup();

   /* Welcome message - must be before space_init. */
   player_message( _("#gWelcome to %s!"), APPNAME );
   player_message( "#g v%s", naev_version(0) );

   /* Now begin to load. */
   diff_load(node); /* Must load first to work properly. */
   unidiff_universeDefer( 0 );
   missions_loadCommodity(node); /* Must be loaded before player. */
   pfaction_load(node); /* Must be loaded before player so the messages show up properly. */
   pnt = player_load(node);
   player.loaded_version = strdup( (version!=NULL) ? version : naev_version(0) );

   /* Sanitize for new version. */
   if (version_diff <= -2) {
      WARN( _("Old version detected. Sanitizing ships for slots") );
      load_compatSlots();
   }

   /* Load more stuff. */
   space_sysLoad(node);
   var_load(node);
   missions_loadActive(node);
   events_loadActive(node);
   news_loadArticles( node );
   hook_load(node);

   /* Initialize the economy. */
   economy_init();
   economy_sysLoad(node);

   /* Initialise the ship log */
   shiplog_new();
   shiplog_load(node);

   /* Check validity. */
   event_checkValidity();

   /* Run the load event trigger. */
   events_trigger( EVENT_TRIGGER_LOAD );

   /* Create escorts in space. */
   player_addEscorts();

   /* Load the GUI. */
   if (gui_load( gui_pick() )) {
      if (player.p->ship->gui != NULL)
         gui_load( player.p->ship->gui );
   }

   /* Land the player. */
   land( pnt, 1 );

   /* Sanitize the GUI. */
   gui_setCargo();
   gui_setShip();

   xmlFreeDoc(doc);

   /* Set loaded. */
   save_loaded = 1;

   return 0;

err_doc:
   xmlFreeDoc(doc);
err:
   WARN( _("Saved game '%s' invalid!"), file);
   return -1;
}

/**
 * @brief Temporary (hopefully) wrapper around xml_parsePhysFS in support of gzipped XML (like .ns files).
 */
static xmlDocPtr load_xml_parsePhysFS( const char* filename )
{
   char buf[PATH_MAX];
   snprintf( buf, sizeof(buf), "%s/%s", PHYSFS_getWriteDir(), filename );
   return xmlParseFile( buf );
}
