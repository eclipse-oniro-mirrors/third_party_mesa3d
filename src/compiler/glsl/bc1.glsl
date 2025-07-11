/*
 * Copyright 2020-2022 Matias N. Goldberg
 * Copyright 2022 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#version 310 es

#if defined(GL_ES) && GL_ES == 1
	// Desktop GLSL allows the const keyword for either compile-time or
	// run-time constants. GLSL ES only allows the keyword for compile-time
	// constants. Since we use const on run-time constants, define it to
	// nothing.
	#define const
#endif

%s // include "CrossPlatformSettings_piece_all.glsl"

#define FLT_MAX 340282346638528859811704183484516925440.0f

layout( location = 0 ) uniform uint p_numRefinements;

uniform sampler2D srcTex;

layout( rgba16ui ) uniform restrict writeonly mediump uimage2D dstTexture;

layout( std430, binding = 1 ) readonly restrict buffer globalBuffer
{
	float2 c_oMatch5[256];
	float2 c_oMatch6[256];
};

layout( local_size_x = 8,  //
		local_size_y = 8,  //
		local_size_z = 1 ) in;

float3 rgb565to888( float rgb565 )
{
	float3 retVal;
	retVal.x = floor( rgb565 / 2048.0f );
	retVal.y = floor( mod( rgb565, 2048.0f ) / 32.0f );
	retVal.z = floor( mod( rgb565, 32.0f ) );
	return floor( retVal * float3( 8.25f, 4.0625f, 8.25f ) );
}

float rgb888to565( float3 rgbValue )
{
	rgbValue.rb = floor( rgbValue.rb * 31.0f / 255.0f + 0.5f );
	rgbValue.g = floor( rgbValue.g * 63.0f / 255.0f + 0.5f );

	return rgbValue.r * 2048.0f + rgbValue.g * 32.0f + rgbValue.b;
}

// linear interpolation at 1/3 point between a and b, using desired rounding type
float3 lerp13( float3 a, float3 b )
{
#ifdef STB_DXT_USE_ROUNDING_BIAS
	// with rounding bias
	return a + floor( ( b - a ) * ( 1.0f / 3.0f ) + 0.5f );
#else
	// without rounding bias
	return floor( ( 2.0f * a + b ) / 3.0f );
#endif
}

/// Unpacks a block of 4 colours from two 16-bit endpoints
void EvalColors( out float3 colours[4], float c0, float c1 )
{
	colours[0] = rgb565to888( c0 );
	colours[1] = rgb565to888( c1 );
	colours[2] = lerp13( colours[0], colours[1] );
	colours[3] = lerp13( colours[1], colours[0] );
}

/** The color optimization function. (Clever code, part 1)
@param outMinEndp16 [out]
	Minimum endpoint, in RGB565
@param outMaxEndp16 [out]
	Maximum endpoint, in RGB565
*/
void OptimizeColorsBlock( const uint srcPixelsBlock[16], out float outMinEndp16, out float outMaxEndp16 )
{
	// determine color distribution
	float3 avgColour;
	float3 minColour;
	float3 maxColour;

	avgColour = minColour = maxColour = unpackUnorm4x8( srcPixelsBlock[0] ).xyz;
	for( int i = 1; i < 16; ++i )
	{
		const float3 currColourUnorm = unpackUnorm4x8( srcPixelsBlock[i] ).xyz;
		avgColour += currColourUnorm;
		minColour = min( minColour, currColourUnorm );
		maxColour = max( maxColour, currColourUnorm );
	}

	avgColour = round( avgColour * 255.0f / 16.0f );
	maxColour *= 255.0f;
	minColour *= 255.0f;

	// determine covariance matrix
	float cov[6];
	for( int i = 0; i < 6; ++i )
		cov[i] = 0.0f;

	for( int i = 0; i < 16; ++i )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;
		float3 rgbDiff = currColour - avgColour;

		cov[0] += rgbDiff.r * rgbDiff.r;
		cov[1] += rgbDiff.r * rgbDiff.g;
		cov[2] += rgbDiff.r * rgbDiff.b;
		cov[3] += rgbDiff.g * rgbDiff.g;
		cov[4] += rgbDiff.g * rgbDiff.b;
		cov[5] += rgbDiff.b * rgbDiff.b;
	}

	// convert covariance matrix to float, find principal axis via power iter
	for( int i = 0; i < 6; ++i )
		cov[i] /= 255.0f;

	float3 vF = maxColour - minColour;

	const int nIterPower = 4;
	for( int iter = 0; iter < nIterPower; ++iter )
	{
		const float r = vF.r * cov[0] + vF.g * cov[1] + vF.b * cov[2];
		const float g = vF.r * cov[1] + vF.g * cov[3] + vF.b * cov[4];
		const float b = vF.r * cov[2] + vF.g * cov[4] + vF.b * cov[5];

		vF.r = r;
		vF.g = g;
		vF.b = b;
	}

	float magn = max3( abs( vF.r ), abs( vF.g ), abs( vF.b ) );
	float3 v;

	if( magn < 4.0f )
	{                  // too small, default to luminance
		v.r = 299.0f;  // JPEG YCbCr luma coefs, scaled by 1000.
		v.g = 587.0f;
		v.b = 114.0f;
	}
	else
	{
		v = trunc( vF * ( 512.0f / magn ) );
	}

	// Pick colors at extreme points
	float3 minEndpoint, maxEndpoint;
	float minDot = FLT_MAX;
	float maxDot = -FLT_MAX;
	for( int i = 0; i < 16; ++i )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;
		const float dotValue = dot( currColour, v );

		if( dotValue < minDot )
		{
			minDot = dotValue;
			minEndpoint = currColour;
		}

		if( dotValue > maxDot )
		{
			maxDot = dotValue;
			maxEndpoint = currColour;
		}
	}

	outMinEndp16 = rgb888to565( minEndpoint );
	outMaxEndp16 = rgb888to565( maxEndpoint );
}

// The color matching function
uint MatchColorsBlock( const uint srcPixelsBlock[16], float3 colour[4] )
{
	uint mask = 0u;
	float3 dir = colour[0] - colour[1];
	float stops[4];

	for( int i = 0; i < 4; ++i )
		stops[i] = dot( colour[i], dir );
	float c0Point = trunc( ( stops[1] + stops[3] ) * 0.5f );
	float halfPoint = trunc( ( stops[3] + stops[2] ) * 0.5f );
	float c3Point = trunc( ( stops[2] + stops[0] ) * 0.5f );

#ifndef BC1_DITHER
	// the version without dithering is straightforward
	for( uint i = 16u; i-- > 0u; )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;

		const float dotValue = dot( currColour, dir );
		mask <<= 2u;

		if( dotValue < halfPoint )
			mask |= ( ( dotValue < c0Point ) ? 1u : 3u );
		else
			mask |= ( ( dotValue < c3Point ) ? 2u : 0u );
	}
#else
	// with floyd-steinberg dithering
	float4 ep1 = float4( 0, 0, 0, 0 );
	float4 ep2 = float4( 0, 0, 0, 0 );

	c0Point *= 16.0f;
	halfPoint *= 16.0f;
	c3Point *= 16.0f;

	for( uint y = 0u; y < 4u; ++y )
	{
		float ditherDot;
		uint lmask, step;

		float3 currColour;
		float dotValue;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4u + 0u] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 3.0f * ep2[1] + 5.0f * ep2[0] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[0] = dotValue - stops[step];
		lmask = step;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4u + 1u] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7.0f * ep1[0] + 3.0f * ep2[2] + 5.0f * ep2[1] + ep2[0] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[1] = dotValue - stops[step];
		lmask |= step << 2u;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4u + 2u] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7.0f * ep1[1] + 3.0f * ep2[3] + 5.0f * ep2[2] + ep2[1] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[2] = dotValue - stops[step];
		lmask |= step << 4u;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4u + 2u] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7.0f * ep1[2] + 5.0f * ep2[3] + ep2[2] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[3] = dotValue - stops[step];
		lmask |= step << 6u;

		mask |= lmask << ( y * 8u );
		{
			float4 tmp = ep1;
			ep1 = ep2;
			ep2 = tmp;
		}  // swap
	}
#endif

	return mask;
}

// The refinement function. (Clever code, part 2)
// Tries to optimize colors to suit block contents better.
// (By solving a least squares system via normal equations+Cramer's rule)
bool RefineBlock( const uint srcPixelsBlock[16], uint mask, inout float inOutMinEndp16,
				  inout float inOutMaxEndp16 )
{
	float newMin16, newMax16;
	const float oldMin = inOutMinEndp16;
	const float oldMax = inOutMaxEndp16;

	if( ( mask ^ ( mask << 2u ) ) < 4u )  // all pixels have the same index?
	{
		// yes, linear system would be singular; solve using optimal
		// single-color match on average color
		float3 rgbVal = float3( 8.0f / 255.0f, 8.0f / 255.0f, 8.0f / 255.0f );
		for( int i = 0; i < 16; ++i )
			rgbVal += unpackUnorm4x8( srcPixelsBlock[i] ).xyz;

		rgbVal = floor( rgbVal * ( 255.0f / 16.0f ) );

		newMax16 = c_oMatch5[uint( rgbVal.r )][0] * 2048.0f +  //
				   c_oMatch6[uint( rgbVal.g )][0] * 32.0f +    //
				   c_oMatch5[uint( rgbVal.b )][0];
		newMin16 = c_oMatch5[uint( rgbVal.r )][1] * 2048.0f +  //
				   c_oMatch6[uint( rgbVal.g )][1] * 32.0f +    //
				   c_oMatch5[uint( rgbVal.b )][1];
	}
	else
	{
		const float w1Tab[4] = float[4]( 3.0f, 0.0f, 2.0f, 1.0f );
		const float prods[4] = float[4]( 589824.0f, 2304.0f, 262402.0f, 66562.0f );
		// ^some magic to save a lot of multiplies in the accumulating loop...
		// (precomputed products of weights for least squares system, accumulated inside one 32-bit
		// register)

		float akku = 0.0f;
		uint cm = mask;
		float3 at1 = float3( 0, 0, 0 );
		float3 at2 = float3( 0, 0, 0 );
		for( int i = 0; i < 16; ++i, cm >>= 2u )
		{
			const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;

			const uint step = cm & 3u;
			const float w1 = w1Tab[step];
			akku += prods[step];
			at1 += currColour * w1;
			at2 += currColour;
		}

		at2 = 3.0f * at2 - at1;

		// extract solutions and decide solvability
		const float xx = floor( akku / 65535.0f );
		const float yy = floor( mod( akku, 65535.0f ) / 256.0f );
		const float xy = mod( akku, 256.0f );

		float2 f_rb_g;
		f_rb_g.x = 3.0f * 31.0f / 255.0f / ( xx * yy - xy * xy );
		f_rb_g.y = f_rb_g.x * 63.0f / 31.0f;

		// solve.
		const float3 newMaxVal = clamp( floor( ( at1 * yy - at2 * xy ) * f_rb_g.xyx + 0.5f ),
										float3( 0.0f, 0.0f, 0.0f ), float3( 31, 63, 31 ) );
		newMax16 = newMaxVal.x * 2048.0f + newMaxVal.y * 32.0f + newMaxVal.z;

		const float3 newMinVal = clamp( floor( ( at2 * xx - at1 * xy ) * f_rb_g.xyx + 0.5f ),
										float3( 0.0f, 0.0f, 0.0f ), float3( 31, 63, 31 ) );
		newMin16 = newMinVal.x * 2048.0f + newMinVal.y * 32.0f + newMinVal.z;
	}

	inOutMinEndp16 = newMin16;
	inOutMaxEndp16 = newMax16;

	return oldMin != newMin16 || oldMax != newMax16;
}

#ifdef BC1_DITHER
/// Quantizes 'srcValue' which is originally in 888 (full range),
/// converting it to 565 and then back to 888 (quantized)
float3 quant( float3 srcValue )
{
	srcValue = clamp( srcValue, 0.0f, 255.0f );
	// Convert 888 -> 565
	srcValue = floor( srcValue * float3( 31.0f / 255.0f, 63.0f / 255.0f, 31.0f / 255.0f ) + 0.5f );
	// Convert 565 -> 888 back
	srcValue = floor( srcValue * float3( 8.25f, 4.0625f, 8.25f ) );

	return srcValue;
}

void DitherBlock( const uint srcPixBlck[16], out uint dthPixBlck[16] )
{
	float3 ep1[4] = float3[4]( float3( 0, 0, 0 ), float3( 0, 0, 0 ), float3( 0, 0, 0 ), float3( 0, 0, 0 ) );
	float3 ep2[4] = float3[4]( float3( 0, 0, 0 ), float3( 0, 0, 0 ), float3( 0, 0, 0 ), float3( 0, 0, 0 ) );

	for( uint y = 0u; y < 16u; y += 4u )
	{
		float3 srcPixel, dithPixel;

		srcPixel = unpackUnorm4x8( srcPixBlck[y + 0u] ).xyz * 255.0f;
		dithPixel = quant( srcPixel + trunc( ( 3.0f * ep2[1] + 5.0f * ep2[0] ) * ( 1.0f / 16.0f ) ) );
		ep1[0] = srcPixel - dithPixel;
		dthPixBlck[y + 0u] = packUnorm4x8( float4( dithPixel * ( 1.0f / 255.0f ), 1.0f ) );

		srcPixel = unpackUnorm4x8( srcPixBlck[y + 1u] ).xyz * 255.0f;
		dithPixel = quant(
			srcPixel + trunc( ( 7.0f * ep1[0] + 3.0f * ep2[2] + 5.0f * ep2[1] + ep2[0] ) * ( 1.0f / 16.0f ) ) );
		ep1[1] = srcPixel - dithPixel;
		dthPixBlck[y + 1u] = packUnorm4x8( float4( dithPixel * ( 1.0f / 255.0f ), 1.0f ) );

		srcPixel = unpackUnorm4x8( srcPixBlck[y + 2u] ).xyz * 255.0f;
		dithPixel = quant(
			srcPixel + trunc( ( 7.0f * ep1[1] + 3.0f * ep2[3] + 5.0f * ep2[2] + ep2[1] ) * ( 1.0f / 16.0f ) ) );
		ep1[2] = srcPixel - dithPixel;
		dthPixBlck[y + 2u] = packUnorm4x8( float4( dithPixel * ( 1.0f / 255.0f ), 1.0f ) );

		srcPixel = unpackUnorm4x8( srcPixBlck[y + 3u] ).xyz * 255.0f;
		dithPixel = quant( srcPixel + trunc( ( 7.0f * ep1[2] + 5.0f * ep2[3] + ep2[2] ) * ( 1.0f / 16.0f ) ) );
		ep1[3] = srcPixel - dithPixel;
		dthPixBlck[y + 3u] = packUnorm4x8( float4( dithPixel * ( 1.0f / 255.0f ), 1.0f ) );

		// swap( ep1, ep2 )
		for( uint i = 0u; i < 4u; ++i )
		{
			float3 tmp = ep1[i];
			ep1[i] = ep2[i];
			ep2[i] = tmp;
		}
	}
}
#endif

void main()
{
	uint srcPixelsBlock[16];

	bool bAllColoursEqual = true;

	// Load the whole 4x4 block
	const uint2 pixelsToLoadBase = gl_GlobalInvocationID.xy << 2u;
	for( uint i = 0u; i < 16u; ++i )
	{
		const uint2 pixelsToLoad = pixelsToLoadBase + uint2( i & 0x03u, i >> 2u );
		const float3 srcPixels0 = OGRE_Load2D( srcTex, int2( pixelsToLoad ), 0 ).xyz;
		srcPixelsBlock[i] = packUnorm4x8( float4( srcPixels0, 1.0f ) );
		bAllColoursEqual = bAllColoursEqual && srcPixelsBlock[0] == srcPixelsBlock[i];
	}

	float maxEndp16, minEndp16;
	uint mask = 0u;

	if( bAllColoursEqual )
	{
		const uint3 rgbVal = uint3( unpackUnorm4x8( srcPixelsBlock[0] ).xyz * 255.0f );
		mask = 0xAAAAAAAAu;
		maxEndp16 =
			c_oMatch5[rgbVal.r][0] * 2048.0f + c_oMatch6[rgbVal.g][0] * 32.0f + c_oMatch5[rgbVal.b][0];
		minEndp16 =
			c_oMatch5[rgbVal.r][1] * 2048.0f + c_oMatch6[rgbVal.g][1] * 32.0f + c_oMatch5[rgbVal.b][1];
	}
	else
	{
#ifdef BC1_DITHER
		uint ditherPixelsBlock[16];
		// first step: compute dithered version for PCA if desired
		DitherBlock( srcPixelsBlock, ditherPixelsBlock );
#else
#	define ditherPixelsBlock srcPixelsBlock
#endif

		// second step: pca+map along principal axis
		OptimizeColorsBlock( ditherPixelsBlock, minEndp16, maxEndp16 );
		if( minEndp16 != maxEndp16 )
		{
			float3 colours[4];
			EvalColors( colours, maxEndp16, minEndp16 );  // Note min/max are inverted
			mask = MatchColorsBlock( srcPixelsBlock, colours );
		}

		// third step: refine (multiple times if requested)
		bool bStopRefinement = false;
		for( uint i = 0u; i < p_numRefinements && !bStopRefinement; ++i )
		{
			const uint lastMask = mask;

			if( RefineBlock( ditherPixelsBlock, mask, minEndp16, maxEndp16 ) )
			{
				if( minEndp16 != maxEndp16 )
				{
					float3 colours[4];
					EvalColors( colours, maxEndp16, minEndp16 );  // Note min/max are inverted
					mask = MatchColorsBlock( srcPixelsBlock, colours );
				}
				else
				{
					mask = 0u;
					bStopRefinement = true;
				}
			}

			bStopRefinement = mask == lastMask || bStopRefinement;
		}
	}

	// write the color block
	if( maxEndp16 < minEndp16 )
	{
		const float tmpValue = minEndp16;
		minEndp16 = maxEndp16;
		maxEndp16 = tmpValue;
		mask ^= 0x55555555u;
	}

	uint4 outputBytes;
	outputBytes.x = uint( maxEndp16 );
	outputBytes.y = uint( minEndp16 );
	outputBytes.z = mask & 0xFFFFu;
	outputBytes.w = mask >> 16u;

	uint2 dstUV = gl_GlobalInvocationID.xy;
	imageStore( dstTexture, int2( dstUV ), outputBytes );
}
