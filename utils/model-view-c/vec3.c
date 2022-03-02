#include "vec3.h"

#include <math.h>

#include "common.h"

void vec3_add( vec3 *out, const vec3 *a, const vec3 *b )
{
   for (int i=0; i<3; i++)
      out->v[i] = a->v[i] + b->v[i];
}
void vec3_sub( vec3 *out, const vec3 *a, const vec3 *b )
{
   for (int i=0; i<3; i++)
      out->v[i] = a->v[i] - b->v[i];
}
void vec3_wadd( vec3 *out, const vec3 *a, const vec3 *b, double wa, double wb )
{
   for (int i=0; i<3; i++)
      out->v[i] = wa*a->v[i] + wb*b->v[i];
}
void vec3_max( vec3 *out, const vec3 *a, const vec3 *b )
{
   for (int i=0; i<3; i++)
      out->v[i] = MAX( a->v[i], b->v[i] );
}
void vec3_min( vec3 *out, const vec3 *a, const vec3 *b )
{
   for (int i=0; i<3; i++)
      out->v[i] = MIN( a->v[i], b->v[i] );
}
double vec3_dot( const vec3 *a, const vec3 *b )
{
   double o = 0.;
   for (int i=0; i<3; i++)
      o += a->v[i] * b->v[i];
   return o;
}
double vec3_dist( const vec3 *a, const vec3 *b )
{
   double o = 0.;
   for (int i=0; i<3; i++)
      o += pow( a->v[i]-b->v[i], 2. );
   return sqrt(o);
}
double vec3_length( const vec3 *a )
{
   double o = 0.;
   for (int i=0; i<3; i++)
      o += pow( a->v[i], 2. );
   return sqrt(o);
}

/**
 * @brief Distance between a point and a triangle.
 *
 * Based on  https://www.geometrictools.com/Documentation/DistancePoint3Triangle3.pdf
 */
double vec3_distPointTriangle( const vec3 *point, const vec3 tri[3] )
{
   vec3 diff, edge0, edge1, res;
   double a00, a01, a11, b0, b1, det, s, t;

   vec3_sub( &diff, &tri[0], point );
   vec3_sub( &edge0, &tri[1], &tri[0] );
   vec3_sub( &edge1, &tri[2], &tri[0] );

   a00 = vec3_dot( &edge0, &edge0 );
   a01 = vec3_dot( &edge0, &edge1 );
   a11 = vec3_dot( &edge1, &edge1 );
   b0  = vec3_dot( &diff,  &edge0 );
   b1  = vec3_dot( &diff,  &edge1 );
   det = MAX( a00*a11 - a01*a01, 0. );
   s   = a01 * b1 - a11 * b0;
   t   = a01 * b0 - a00 * b1;

   if (s + t <= det) {
      if (s < 0.) {
         if (t < 0.) { // region 4
            if (b0 < 0.) {
               t = 0.;
               if (-b0 >= a00)
                  s = 1.;
               else
                  s = -b0 / a00;
            }
            else {
               s = 0.;
               if (b1 >= 0.)
                  t = 0.;
               else if (-b1 >= a11)
                  t = 1.;
               else
                  t = -b1 / a11;
            }
         }
         else { // region 3
            s = 0.;
            if (b1 >= 0.)
               t = 0.;
            else if (-b1 >= a11)
               t = 1.;
            else
               t = -b1 / a11;
         }
      }
      else if (t < 0.) { // region 5
         t = 0.;
         if (b0 >= 0.)
            s = 0.;
         else if (-b0 >= a00)
            s = 1.;
         else
            s = -b0 / a00;
      }
      else { // region 0
         // minimum at interior point
         s /= det;
         t /= det;
      }
   }
   else {
      double tmp0, tmp1, numer, denom;

      if (s < 0.) { // region 2
         tmp0 = a01 + b0;
         tmp1 = a11 + b1;
         if (tmp1 > tmp0) {
            numer = tmp1 - tmp0;
            denom = a00 - 2. * a01 + a11;
            if (numer >= denom) {
               s = 1.;
               t = 0.;
            }
            else {
               s = numer / denom;
               t = 1. - s;
            }
         }
         else {
            s = 0.;
            if (tmp1 <= 0.)
               t = 1.;
            else if (b1 >= 0.)
               t = 0.;
            else
               t = -b1 / a11;
         }
      }
      else if (t < 0.) { // region 6
         tmp0 = a01 + b1;
         tmp1 = a00 + b0;
         if (tmp1 > tmp0) {
            numer = tmp1 - tmp0;
            denom = a00 - 2. * a01 + a11;
            if (numer >= denom) {
               t = 1.;
               s = 0.;
            }
            else {
               t = numer / denom;
               s = 1. - t;
            }
         }
         else {
            t = 0.;
            if (tmp1 <= 0.)
               s = 1.;
            else if (b0 >= 0.)
               s = 0.;
            else
               s = -b0 / a00;
         }
      }
      else { // region 1
         numer = a11 + b1 - a01 - b0;
         if (numer <= 0.) {
            s = 0.;
            t = 1.;
         }
         else {
            denom = a00 - 2. * a01 + a11;
            if (numer >= denom) {
               s = 1.;
               t = 0.;
            }
            else {
               s = numer / denom;
               t = 1. - s;
            }
         }
      }
   }

   vec3_wadd( &res, &edge0, &edge1, s, t );
   vec3_add(  &res, &res,   &tri[0] );
   return vec3_dist( point, &res );
   /*
   result.closest[0] = point;
   result.closest[1] = triangle.v[0] + s * edge0 + t * edge1;
   diff = result.closest[0] - result.closest[1];
   result.sqrDistance = Dot(diff, diff);
   result.distance = std::sqrt(result.sqrDistance);
   result.barycentric[0] = one - s - t;
   result.barycentric[1] = s;
   result.barycentric[2] = t;
   return result;
   */
}