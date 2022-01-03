#include "lib/simplex.glsl"

uniform float time;
uniform vec2 globalpos;
in vec2 localpos;
out vec4 colour_out;

const int ITERATIONS    = 2;
const float SCALAR      = 2.0;
const float SCALE       = 3.0;
const float TIME_SCALE  = 10.0;
const float smoothness  = 0.5;

void main (void)
{
   vec3 uv;

   /* Fallout */
   float dist = length(localpos);
   dist = (dist < 1.0-smoothness) ? 1.0 : (1.0 - dist) / smoothness;
   float alpha = smoothstep( 0.0, 1.0, dist );
   if (alpha <= 0.0)
      discard;

   /* Calculate coordinates */
   uv.xy = (localpos + globalpos) * 2.0;
   uv.z += time * 0.3;

   /* Create the noise */
   float f = 0.0;
   for (int i=0; i<ITERATIONS; i++) {
      float scale = pow(SCALAR, i);
      f += (snoise( uv * scale )*0.5 + 0.2) / scale;
   }

   const vec4 colour = vec4( 0.937, 0.102, 0.300, 0.8 );
   colour_out =  mix( vec4(0.0), colour, f );
   colour_out *= alpha;
}
