/* 
 * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <optix.h>
#include <optixu/optixu_math_namespace.h>
#include "helpers.h"
#include "prd.h"
#include "random.h"
#include "commonStructs.h"
#include "areaLight.h"
#include "point.h"
#include <vector>

using namespace optix;

rtDeclareVariable( float3, shading_normal, attribute shading_normal, ); 
rtDeclareVariable( float3, geometric_normal, attribute geometric_normal, );
rtDeclareVariable(float3, tangent_direction, attribute tangent_direction, );
rtDeclareVariable(float3, bitangent_direction, attribute bitangent_direction, );

rtDeclareVariable( float3, texcoord, attribute texcoord, );
rtDeclareVariable( float, t_hit, rtIntersectionDistance, );

rtDeclareVariable(optix::Ray, ray,   rtCurrentRay, );
rtDeclareVariable(PerRayData_radiance, prd_radiance, rtPayload, );
rtDeclareVariable(PerRayData_shadow,   prd_shadow, rtPayload, );
rtDeclareVariable(float, scene_epsilon, , );

// Diffuse albedo
rtDeclareVariable( float3, albedo, , );
rtTextureSampler<float4, 2> albedoMap;
rtDeclareVariable( int, isAlbedoTexture, , );
rtTextureSampler<float4, 2> normalMap;
rtDeclareVariable( int, isNormalTexture, , );


// The area Light Buffer
rtDeclareVariable(int, isAreaLight, , );
rtDeclareVariable(int, areaTriangleNum, , );
rtBuffer<areaLight> areaLights;
rtBuffer<float> areaLightCDF;
rtBuffer<float> areaLightPDF;

// Environmental Lighting 
rtDeclareVariable(int, isEnvmap, , );
rtTextureSampler<float4, 2> envmap;
rtBuffer<float, 2> envcdfV;
rtBuffer<float, 2> envcdfH;
rtBuffer<float, 2> envpdf;
rtDeclareVariable(float, infiniteFar, , );

// Point lighting 
rtDeclareVariable(int, isPointLight, , );
rtDeclareVariable(int, pointLightNum, , );
rtBuffer<Point> pointLights;

// Geometry Group
rtDeclareVariable( rtObject, top_object, , );


// Samplling the area Light
RT_CALLABLE_PROGRAM void sampleAreaLight(unsigned int& seed, float3& radiance, float3& position, float3& normal, float& pdfAreaLight){
    float randf = rnd(seed);

    int left = 0, right = areaTriangleNum;
    int middle = int( (left + right) / 2);
    while(left < right){
        if(areaLightCDF[middle] <= randf)
            left = middle + 1;
        else if(areaLightCDF[middle] > randf)
            right = middle;
        middle = int( (left + right) / 2);
    }
    areaLight L = areaLights[left];
    
    float3 v1 = L.vertices[0];
    float3 v2 = L.vertices[1];
    float3 v3 = L.vertices[2];

    normal = cross(v2 - v1, v3 - v1);
    float area = 0.5 * length(normal);
    normal = normalize(normal);

    float ep1 = rnd(seed);
    float ep2 = rnd(seed);
    
    float u = 1 - sqrt(ep1);
    float v = ep2 * sqrt(ep1);

    position = v1 + (v2 - v1) * u + (v3 - v1) * v;

    radiance = L.radiance;
    pdfAreaLight = areaLightPDF[left] /  fmaxf(area, 1e-14);
}

// Sampling the environmnetal light
RT_CALLABLE_PROGRAM float3 EnvUVToDirec(float u, float v){ 
    // Turn uv coordinate into direction
    float theta = 2 * (u - 0.5) * M_PIf;
    float phi = M_PIf * (1 - v); 
    return make_float3(
                sinf(phi) * sinf(theta),
                cosf(phi),
                sinf(phi) * cosf(theta)
            );
}
RT_CALLABLE_PROGRAM float2 EnvDirecToUV(const float3& direc){ 
    float theta = atan2f( direc.x, direc.z );
    float phi = M_PIf - acosf(direc.y );
    float u = theta * (0.5f * M_1_PIf) + 0.5;
    if(u > 1)
        u = u-1;
    float v     = phi / M_PIf;
    return make_float2(u, v);
}
RT_CALLABLE_PROGRAM float EnvDirecToPdf(const float3& direc){
    float2 uv = EnvDirecToUV(direc);
    size_t2 pdfSize = envpdf.size();
    float u = uv.x, v = uv.y;
    int rowId = int(v * (pdfSize.y-1) );
    int colId = int(u * (pdfSize.x-1) );
    return envpdf[make_uint2(colId, rowId ) ];
}
RT_CALLABLE_PROGRAM void sampleEnvironmapLight(unsigned int& seed, float3& radiance, float3& direction, float& pdfSolidEnv){
    float z1 = rnd(seed);
    float z2 = rnd(seed);
    
    int ncols = envcdfH.size().x;
    int nrows = envcdfH.size().y;

    // Sample the row 
    float u = 0, v = 0;
    int rowId = 0;
    {
        int left = 0, right = nrows-1;
        while(right > left){
            int mid = (left + right) / 2;
            if(envcdfV[ make_uint2(0, mid) ] >= z1)
                right = mid;
            else if(envcdfV[ make_uint2(0, mid) ] < z1)
                left = mid + 1;
        }
        float up = envcdfV[make_uint2(0, left) ];
        float down = (left == 0) ? 0 : envcdfV[make_uint2(0, left-1) ];
        v = ( (z1 - down) / fmaxf( (up - down), 1e-14) + left) / float(nrows);
        rowId = left;
    }

    // Sample the column
    int colId = 0;
    {
        int left = 0; int right = ncols - 1;
        while(right > left){
            int mid = (left + right) / 2;
            if(envcdfH[ make_uint2(mid, rowId) ] >= z2)
                right = mid;
            else if(envcdfH[ make_uint2(mid, rowId) ] < z2)
                left = mid + 1;
        }
        float up = envcdfH[make_uint2(left, rowId) ];
        float down = (left == 0) ? 0 : envcdfH[make_uint2(left-1, rowId) ];
        u = ((z2 - down) / fmaxf((up - down), 1e-14) + left) / float(ncols);
        colId = left;
    }
    
    // Turn uv coordinate into direction
    direction = EnvUVToDirec(u, v);
    pdfSolidEnv = envpdf[make_uint2(colId, rowId) ];
    radiance = make_float3(tex2D(envmap, u, v) );
}

// Computing the pdfSolidAngle of BRDF giving a direction 
RT_CALLABLE_PROGRAM float pdf(const float3& L, const float3& V, const float3& N)
{
    float NoL = fmaxf(dot(N, L), 0);
    float pdf = NoL / M_PIf; 
    return fmaxf(pdf, 1e-14);
}

RT_CALLABLE_PROGRAM float3 evaluate(const float3& albedoValue, const float3& N, const float3& V, const float3& L, const float3& radiance)
{   
    float NoL = fmaxf(dot(N, L), 1e-14);
    float3 intensity = albedoValue / M_PIf * NoL * radiance; 
    return intensity;
}

RT_CALLABLE_PROGRAM void sample(unsigned& seed, 
        const float3& albedoValue, const float3& N, const float3& V, 
        optix::Onb& onb, 
        float3& attenuation, float3& direction, float& pdfSolid)
{
    const float z1 = rnd( seed );
    const float z2 = rnd( seed );

    float3 L;
    cosine_sample_hemisphere(z1, z2, L);
    onb.inverse_transform(L);
    direction = L;
    attenuation = attenuation * albedoValue;
    pdfSolid = pdf(L, V, N);
}


RT_PROGRAM void closest_hit_radiance()
{
    const float3 world_shading_normal   = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, shading_normal ) );
    const float3 world_geometric_normal = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, geometric_normal ) );
    float3 ffnormal = faceforward( world_shading_normal, -ray.direction, world_geometric_normal );

    
    float3 albedoValue;
    if(isAlbedoTexture == 0){
        albedoValue = albedo;
    }
    else{
        albedoValue = make_float3(tex2D(albedoMap, texcoord.x, texcoord.y) );
        albedoValue.x = pow(albedoValue.x, 2.2);
        albedoValue.y = pow(albedoValue.y, 2.2);
        albedoValue.z = pow(albedoValue.z, 2.2);
    }
   
    float3 V = normalize(-ray.direction );
    if(dot(ffnormal, V) < 0)
        ffnormal = -ffnormal;
    
    float3 N;
    if( isNormalTexture == 0){
        N = ffnormal;
    }
    else{
        N = make_float3(tex2D(normalMap, texcoord.x, texcoord.y) );
        N = normalize(2 * N - 1);
        N = N.x * tangent_direction 
            + N.y * bitangent_direction 
            + N.z * ffnormal;
    }
    N = normalize(N );
    optix::Onb onb(N );

    
    float3 hitPoint = ray.origin + t_hit * ray.direction;
    prd_radiance.origin = hitPoint;

    // Connect to the area Light
    {
        if(isAreaLight == 1){
            float3 position, radiance, normal;
            float pdfAreaLight;
            sampleAreaLight(prd_radiance.seed, radiance, position, normal, pdfAreaLight);
   
            float Dist = length(position - hitPoint);
            float3 L = normalize(position - hitPoint);

            if(fmaxf(dot(N, L), 0.0) * fmaxf(dot(V, N), 0.0) > 0 ){
                float cosPhi = dot(L, normal);
                cosPhi = (cosPhi < 0) ? -cosPhi : cosPhi;

                Ray shadowRay = make_Ray(hitPoint + 0.1 * L * scene_epsilon, L, 1, scene_epsilon, Dist - scene_epsilon);
                PerRayData_shadow prd_shadow; 
                prd_shadow.inShadow = false;
                rtTrace(top_object, shadowRay, prd_shadow);
                if(prd_shadow.inShadow == false)
                {
                    float3 intensity = evaluate(albedoValue, N, V, L, radiance) * cosPhi / Dist / Dist;
                    float pdfSolidBRDF = pdf(L, V, N);
                    float pdfAreaBRDF = pdfSolidBRDF * cosPhi / Dist / Dist;

                    float pdfAreaLight2 = pdfAreaLight * pdfAreaLight;
                    float pdfAreaBRDF2 = pdfAreaBRDF * pdfAreaBRDF;

                    prd_radiance.radiance += intensity * pdfAreaLight / fmaxf(pdfAreaBRDF2 + pdfAreaLight2, 1e-14) * prd_radiance.attenuation;
                }
            }
        }
    }

    // Connect to point light 
    {
        if(isPointLight == 1){
            // Connect to every point light 
            for(int i = 0; i < pointLightNum; i++){
                float3 position = pointLights[i].position;
                float3 radiance = pointLights[i].intensity;
                float3 L = normalize(position - hitPoint);
                float Dist = length(position - hitPoint);
                
                if(fmaxf(dot(N, L), 0.0) * fmaxf(dot(N, V), 0.0) > 0 ){
                    Ray shadowRay = make_Ray(hitPoint + 0.1 * L * scene_epsilon, L, 1, scene_epsilon, Dist - scene_epsilon);
                    PerRayData_shadow prd_shadow; 
                    prd_shadow.inShadow = false;
                    rtTrace(top_object, shadowRay, prd_shadow);
                    if(prd_shadow.inShadow == false){
                        float3 intensity = evaluate(albedoValue, N, V, L, radiance) / Dist / Dist;
                        prd_radiance.radiance += intensity * prd_radiance.attenuation;
                    }
                }
            }
        }
    }

    // Connect to the environmental map 
    { 
        if(isEnvmap == 1){
            float3 L, radiance;
            float pdfSolidEnv;
            sampleEnvironmapLight(prd_radiance.seed, radiance, L, pdfSolidEnv);

            if( fmaxf(dot(L, N), 0.0) * fmaxf(dot(V, N), 0.0)  > 0 ){
                Ray shadowRay = make_Ray(hitPoint + 0.1*scene_epsilon, L, 1, scene_epsilon, infiniteFar);
                PerRayData_shadow prd_shadow;
                prd_shadow.inShadow = false;
                rtTrace(top_object, shadowRay, prd_shadow);
                if(prd_shadow.inShadow == false)
                {
                    float3 intensity = evaluate(albedoValue, N, V, L, radiance);
                    float pdfSolidBRDF = pdf(L, V, N);
                    float pdfSolidBRDF2 = pdfSolidBRDF * pdfSolidBRDF;
                    float pdfSolidEnv2 = pdfSolidEnv * pdfSolidEnv;
                    prd_radiance.radiance += intensity * pdfSolidEnv /
                        fmaxf( (pdfSolidEnv2 + pdfSolidBRDF2), 1e-14) * prd_radiance.attenuation; 
                }
            }
        }
    }

    // Finish updating the ray
    sample(prd_radiance.seed,
            albedoValue, N, V,
            onb,
            prd_radiance.attenuation, prd_radiance.direction, prd_radiance.pdf);
}

// any_hit_shadow program for every material include the lighting should be the same
RT_PROGRAM void any_hit_shadow()
{
    prd_shadow.inShadow = true;
    rtTerminateRay();
}

