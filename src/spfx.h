/*
 * See Licensing and Copyright notice in naev.h
 */
#pragma once

#include "ntime.h"
#include "opengl.h"
#include "physics.h"

#define SPFX_LAYER_FRONT   0 /**< Front spfx layer. */
#define SPFX_LAYER_MIDDLE  1 /**< Middle spfx layer. */
#define SPFX_LAYER_BACK    2 /**< Back spfx layer. */

#define SPFX_DAMAGE_DECAY  0.5 /**< Rate at which the damage strength goes down. */
#define SPFX_DAMAGE_MOD    1.5 /**< How damage spfx gets modified (base is armour_dmg / total_armour */
#define SPFX_DAMAGE_MAX    1.0 /**< Maximum value of the damage strength. */

#define SPFX_SHAKE_DECAY   0.3 /**< Rumble decay parameter */
#define SPFX_SHAKE_MOD     1.0 /**< Rumblemax parameter */
#define SPFX_SHAKE_MAX     1.0 /**< Rumblemax parameter */

/**
 * @brief Represents the appearance characteristics for a given trail mode.
 */
typedef struct TrailStyle_ {
   glColour col; /**< Colour. */
   float thick;  /**< Thickness. */
} TrailStyle;

/**
 * @brief IDs for the type of emission. (It's modal: one trail can have segments of different types.)
 */
typedef enum TrailMode_ {
   MODE_IDLE, MODE_GLOW, MODE_AFTERBURN, MODE_JUMPING, MODE_NONE,
   MODE_MAX
} TrailMode;

#define MODE_TAGS {"idle", "glow", "afterburn", "jumping", "none",}

/**
 * @brief represents a set of styles for trails.
 */
typedef struct TrailSpec_ {
   char* name;       /**< Trail definition's name. */
   char *filename;   /** File the the trail spec is loaded from. */
   double ttl;       /**< Time To Life (in seconds). */
   float def_thick;  /**< Default thickness, relevant while loading. */
   GLuint type;      /**< Shader to use. */
   TrailStyle style[MODE_MAX]; /**< Appearance characteristics for each trail mode. */
   int nebula;       /**< Whether or not the trail should be only active in the nebula. */
} TrailSpec;

typedef struct TrailPoint {
   GLfloat x, y;     /**< Control points for the trail. */
   GLfloat t;        /**< Timer, normalized to the time to live of the trail (starts at 1, ends at 0). */
   TrailMode mode;   /**< Type of trail emission at this point. */
} TrailPoint;

/**
 * @struct Trail_spfx
 *
 * @brief A trail generated by a ship or an ammo.
 */
typedef struct Trail_spfx_ {
   const TrailSpec *spec;
   TrailPoint *point_ringbuf; /**< Circular buffer (malloced/freed) of trail points. */
   size_t capacity;  /**< Buffer size, guaranteed to be a power of 2. */
   size_t iread;     /**< Start index (NOT reduced modulo capacity). */
   size_t iwrite;    /**< End index (NOT reduced modulo capacity). */
   int refcount;     /**< Number of referrers. If 0, trail dies after its TTL. */
   double dt;        /**< Timer accumulator (in seconds). */
   GLfloat r;        /**< Random variable between 0 and 1 to make each trail unique. */
   unsigned int ontop; /**< Boolean to decide if the trail is drawn before or after the ship. */
} Trail_spfx;

/** @brief Indexes into a trail's circular buffer.  */
#define trail_at( trail, i ) ( (trail)->point_ringbuf[ (i) & ((trail)->capacity - 1) ] )
/** @brief Returns the number of elements of a trail's circular buffer.  */
#define trail_size( trail ) ( (trail)->iwrite - (trail)->iread )
/** @brief Returns the first element of a trail's circular buffer.  */
#define trail_front( trail ) trail_at( trail, (trail)->iread )
/** @brief Returns the last element of a trail's circular buffer.  */
#define trail_back( trail ) trail_at( trail, (trail)->iwrite-1 )

/*
 * stack manipulation
 */
int spfx_get( char* name );
const TrailSpec* trailSpec_get( const char* name );
void spfx_add( int effect,
      const double px, const double py,
      const double vx, const double vy,
      int layer );

/*
 * stack mass manipulation functions
 */
void spfx_update( const double dt, const double real_dt );
void spfx_render( int layer, double dt );
void spfx_clear (void);
Trail_spfx* spfx_trail_create( const TrailSpec* spec );
void spfx_trail_sample( Trail_spfx* trail, double x, double y, TrailMode mode, int force );
void spfx_trail_remove( Trail_spfx* trail );
void spfx_trail_draw( const Trail_spfx* trail );

/*
 * Misc effects.
 */
void spfx_shake( double mod );
void spfx_damage( double mod );

/*
 * other effects
 */
void spfx_cinematic (void);

/*
 * spfx effect loading and freeing
 */
int spfx_load (void);
void spfx_free (void);
