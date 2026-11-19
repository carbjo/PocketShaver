/*
 *  gl_render_contract.h - OpenGL primitive traversal, clipping and raster state.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_RENDER_CONTRACT_H
#define GL_RENDER_CONTRACT_H
#include "gl_vertex_pipeline.h"
#include <algorithm>

// Original GL primitive boundaries (including quad edges) are shared by
// feedback, selection and non-fill polygon rasterization.
template<class Emit> static inline void GLVisitPrimitiveIndices(uint32_t mode, size_t n, Emit emit)
{
    auto send=[&](std::initializer_list<size_t> indices, bool polygon, bool reset) {
        emit(std::vector<size_t>(indices), polygon, reset);
    };
    switch(mode) {
    case 0: for(size_t i=0;i<n;++i) send({i},false,true); break;
    case 1: for(size_t i=0;i+1<n;i+=2) send({i,i+1},false,true); break;
    case 2: case 3:
        for(size_t i=0;i+1<n;++i) send({i,i+1},false,i==0);
        if(mode==2 && n>1) send({n-1,0},false,false); break;
    case 4: for(size_t i=0;i+2<n;i+=3) send({i,i+1,i+2},true,true); break;
    case 5: for(size_t i=0;i+2<n;++i) send({i+i%2,i+1-i%2,i+2},true,true); break;
    case 6: for(size_t i=1;i+1<n;++i) send({0,i,i+1},true,true); break;
    case 7: for(size_t i=0;i+3<n;i+=4) send({i,i+1,i+2,i+3},true,true); break;
    case 8: for(size_t i=0;i+3<n;i+=2) send({i,i+1,i+3,i+2},true,true); break;
    case 9: if(n>=3) { std::vector<size_t> indices(n);for(size_t i=0;i<n;++i)indices[i]=i;emit(indices,true,true); } break;
    }
}

static inline void GLContractLight(const GLContext &ctx,const GLMetalVertex &v,int face,float out[4])
{
    if(!ctx.lighting_enabled) {std::memcpy(out,v.color,16);return;}
    auto dot=[](const double *a,const double *b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];};
    auto normalize=[&](double *a){double length=std::sqrt(dot(a,a));if(length>0)for(int k=0;k<3;++k)a[k]/=length;};
    const auto &material=v.material[face];const float *mv=ctx.modelview_stack[ctx.modelview_depth];
    double inverse[4][4]={};GLTextureInverseMatrix(inverse,mv);
    double normal[3]={},eye[3]={};
    for(int r=0;r<3;++r)for(int k=0;k<3;++k)normal[r]+=inverse[k][r]*v.normal[k];
    if(ctx.normalize)normalize(normal);if(face)for(double &n:normal)n=-n;
    for(int r=0;r<3;++r)for(int k=0;k<4;++k)eye[r]+=mv[k*4+r]*v.lighting_position[k];
    double color[3];for(int k=0;k<3;++k)color[k]=material.emission[k]+ctx.light_model_ambient[k]*material.ambient[k];
    for(const auto &light:ctx.lights) {
        if(!light.enabled)continue;double direction[3];double attenuation=1;
        for(int k=0;k<3;++k)direction[k]=light.position[k]-(light.position[3]!=0?eye[k]:0);
        double distance=std::sqrt(dot(direction,direction));normalize(direction);
        if(light.position[3]!=0)attenuation=1/(light.constant_attenuation+light.linear_attenuation*distance+light.quadratic_attenuation*distance*distance);
        if(light.spot_cutoff!=180) {
            double spot[3]={light.spot_direction[0],light.spot_direction[1],light.spot_direction[2]};normalize(spot);
            double cosine=-dot(direction,spot);if(cosine<std::cos(light.spot_cutoff*3.141592653589793/180))continue;
            attenuation*=std::pow(std::max(0.,cosine),light.spot_exponent);
        }
        double diffuse=std::max(0.,dot(normal,direction)),specular=0;
        if(diffuse>0) {
            double viewer[3]={0,0,1};if(ctx.light_model_local_viewer){for(int k=0;k<3;++k)viewer[k]=-eye[k];normalize(viewer);}
            double half[3];for(int k=0;k<3;++k)half[k]=direction[k]+viewer[k];normalize(half);
            specular=material.shininess==0?1:std::pow(std::max(0.,dot(normal,half)),material.shininess);
        }
        for(int k=0;k<3;++k)color[k]+=attenuation*(light.ambient[k]*material.ambient[k]+diffuse*light.diffuse[k]*material.diffuse[k]+specular*light.specular[k]*material.specular[k]);
    }
    for(int k=0;k<3;++k)out[k]=float(std::max(0.,std::min(1.,color[k])));out[3]=std::max(0.f,std::min(1.f,material.diffuse[3]));
}

struct GLContractVertex {
    GLMetalVertex raster;
    bool edge=true;
    double clip[4], eye[4];
    float color[4], texcoord[4];
};
static inline GLContractVertex GLContractInterpolate(const GLContractVertex &a,const GLContractVertex &b,double t)
{
    GLContractVertex v;v.raster=a.raster;
    for(int i=0;i<4;++i) {
        v.raster.position[i]=float(a.raster.position[i]+(b.raster.position[i]-a.raster.position[i])*t);
        v.raster.color[i]=float(a.raster.color[i]+(b.raster.color[i]-a.raster.color[i])*t);
        v.raster.texcoord[i]=float(a.raster.texcoord[i]+(b.raster.texcoord[i]-a.raster.texcoord[i])*t);
        v.raster.texcoord1[i]=float(a.raster.texcoord1[i]+(b.raster.texcoord1[i]-a.raster.texcoord1[i])*t);
    }
    for(int i=0;i<3;++i)v.raster.secondary_color[i]=float(a.raster.secondary_color[i]+(b.raster.secondary_color[i]-a.raster.secondary_color[i])*t);
    for(int i=0;i<4;++i) {
        v.clip[i]=a.clip[i]+(b.clip[i]-a.clip[i])*t;
        v.eye[i]=a.eye[i]+(b.eye[i]-a.eye[i])*t;
        v.color[i]=float(a.color[i]+(b.color[i]-a.color[i])*t);
        v.texcoord[i]=float(a.texcoord[i]+(b.texcoord[i]-a.texcoord[i])*t);
    }
    return v;
}
static inline double GLContractDistance(const GLContext &ctx,const GLContractVertex &v,int plane)
{
    if(plane<6) return v.clip[3]+((plane&1)?-v.clip[plane/2]:v.clip[plane/2]);
    if(!ctx.clip_plane_enabled[plane-6])return 1;
    double distance=0;for(int k=0;k<4;++k)distance+=ctx.clip_planes[plane-6][k]*v.eye[k];return distance;
}
static inline void GLContractClip(const GLContext &ctx,std::vector<GLContractVertex> &v,bool polygon)
{
    for(int plane=0;plane<12 && !v.empty();++plane) {
        if(!polygon) {
            if(v.size()==1) {if(GLContractDistance(ctx,v[0],plane)<0)v.clear();continue;}
            double a=GLContractDistance(ctx,v[0],plane),b=GLContractDistance(ctx,v[1],plane);
            if(a<0 && b<0) {v.clear();break;}
            if((a<0)!=(b<0)) {auto intersection=GLContractInterpolate(v[0],v[1],a/(a-b));v[a<0?0:1]=intersection;}
        } else {
            std::vector<GLContractVertex> out;auto previous=v.back();double a=GLContractDistance(ctx,previous,plane);
            for(const auto &current:v) {double b=GLContractDistance(ctx,current,plane);
                if((a<0)!=(b<0)){auto intersection=GLContractInterpolate(previous,current,a/(a-b));intersection.edge=a<0?previous.edge:true;out.push_back(intersection);}
                if(b>=0)out.push_back(current);previous=current;a=b;
            }
            v.swap(out);
        }
    }
    for(const auto &vertex:v) if(!std::isfinite(vertex.clip[3]) || vertex.clip[3]<=0) {v.clear();break;}
}
static inline bool GLContractFrontFacing(const GLContext &ctx,const std::vector<GLContractVertex> &v)
{
    double area=0;
    for(size_t i=0;i<v.size();++i) {const auto &a=v[i],&b=v[(i+1)%v.size()];area+=(a.clip[0]/a.clip[3])*(b.clip[1]/b.clip[3])-(b.clip[0]/b.clip[3])*(a.clip[1]/a.clip[3]);}
    return ctx.front_face==0x0900 ? area<0 : area>0;
}
static inline bool GLContractCulled(const GLContext &ctx,bool front)
{
    return ctx.cull_face_enabled && (ctx.cull_face_mode==0x0408 || ctx.cull_face_mode==(front?0x0404u:0x0405u));
}
static inline double GLContractDepth(const GLContext &ctx,const GLContractVertex &v)
{
    return std::max(0.,std::min(1.,ctx.depth_range_near+(v.clip[2]/v.clip[3]+1)*0.5*(ctx.depth_range_far-ctx.depth_range_near)));
}
static inline void GLContractFeedbackVertex(GLContext *ctx,const GLContractVertex &v)
{
    GLFeedbackWrite(ctx,float(ctx->viewport[0]+(v.clip[0]/v.clip[3]+1)*0.5*ctx->viewport[2]));
    GLFeedbackWrite(ctx,float(ctx->viewport[1]+(v.clip[1]/v.clip[3]+1)*0.5*ctx->viewport[3]));
    if(ctx->feedback_type!=0x0600)GLFeedbackWrite(ctx,float(GLContractDepth(*ctx,v)));
    if(ctx->feedback_type==0x0604)GLFeedbackWrite(ctx,float(v.clip[3]));
    if(ctx->feedback_type>=0x0602)for(float color:v.color)GLFeedbackWrite(ctx,color);
    if(ctx->feedback_type>=0x0603)for(float coordinate:v.texcoord)GLFeedbackWrite(ctx,coordinate);
}
static inline GLContractVertex GLContractTransform(const GLContext &ctx,const GLMetalVertex &input)
{
    GLContractVertex v;v.raster=input;
    for(int r=0;r<4;++r) {v.eye[r]=0;for(int c=0;c<4;++c)v.eye[r]+=ctx.modelview_stack[ctx.modelview_depth][c*4+r]*input.position[c];}
    for(int r=0;r<4;++r) {v.clip[r]=0;for(int c=0;c<4;++c)v.clip[r]+=ctx.projection_stack[ctx.projection_depth][c*4+r]*v.eye[c];}
    GLContractLight(ctx,input,0,v.color);std::memcpy(v.texcoord,input.texcoord,sizeof(v.texcoord));
    return v;
}

static inline float GLLineRasterLength(const GLContext &ctx,const GLMetalVertex &a,const GLMetalVertex &b)
{
    auto first=GLContractTransform(ctx,a),last=GLContractTransform(ctx,b);
    if(first.clip[3]==0 || last.clip[3]==0)return 0;
    double x=(last.clip[0]/last.clip[3]-first.clip[0]/first.clip[3])*ctx.viewport[2]*.5;
    double y=(last.clip[1]/last.clip[3]-first.clip[1]/first.clip[3])*ctx.viewport[3]*.5;
    return float(std::max(std::abs(x),std::abs(y)));
}
static inline void GLPrepareLineStipple(const GLContext &ctx,std::vector<GLMetalVertex> &vertices,float base=0)
{
    if(ctx.im_mode>3)return;
    for(size_t i=0;i<vertices.size();++i) {
        if(i==0 || (ctx.im_mode==1 && i%2==0))vertices[i].stipple_distance=base;
        else vertices[i].stipple_distance=vertices[i-1].stipple_distance+GLLineRasterLength(ctx,vertices[i-1],vertices[i]);
    }
}

static inline bool GLProcessRenderMode(GLContext *ctx)
{
    if(ctx->render_mode!=0x1c01 && ctx->render_mode!=0x1c02)return false;
    std::vector<GLMetalVertex> converted;GLConvertDrawVertices(*ctx,ctx->im_vertices,converted);
    std::vector<GLContractVertex> vertices(converted.size());
    for(size_t i=0;i<converted.size();++i) {
        auto &v=vertices[i];const auto &input=converted[i];v.raster=input;
        for(int r=0;r<4;++r) {v.eye[r]=0;for(int c=0;c<4;++c)v.eye[r]+=ctx->modelview_stack[ctx->modelview_depth][c*4+r]*input.position[c];}
        for(int r=0;r<4;++r) {v.clip[r]=0;for(int c=0;c<4;++c)v.clip[r]+=ctx->projection_stack[ctx->projection_depth][c*4+r]*v.eye[c];}
        GLContractLight(*ctx,input,0,v.color);std::memcpy(v.texcoord,input.texcoord,sizeof(v.texcoord));
    }
    GLVisitPrimitiveIndices(ctx->im_mode,vertices.size(),[&](const std::vector<size_t> &indices,bool polygon,bool reset) {
        std::vector<GLContractVertex> primitive;for(size_t i:indices)primitive.push_back(vertices[i]);
        if(polygon && ctx->light_model_two_side && !GLContractFrontFacing(*ctx,primitive))
            for(size_t j=0;j<indices.size();++j)GLContractLight(*ctx,converted[indices[j]],1,primitive[j].color);
        if(ctx->shade_model==0x1d00) {
            const size_t provoking=ctx->im_mode==9?0:ctx->im_mode==8?indices.size()-2:indices.size()-1;
            float color[4];std::memcpy(color,primitive[provoking].color,16);
            for(auto &v:primitive)std::memcpy(v.color,color,16);
        }
        GLContractClip(*ctx,primitive,polygon);if(primitive.empty())return;
        if(polygon && GLContractCulled(*ctx,GLContractFrontFacing(*ctx,primitive)))return;
        if(ctx->render_mode==0x1c02) {
            double low=1,high=0;for(const auto &v:primitive){double z=GLContractDepth(*ctx,v);low=std::min(low,z);high=std::max(high,z);}
            GLSelectionRecordDepthRange(ctx,low,high);
        } else {
            GLFeedbackWrite(ctx,float(polygon?0x0703:primitive.size()==1?0x0701:reset?0x0707:0x0702));
            if(polygon)GLFeedbackWrite(ctx,float(primitive.size()));
            for(const auto &v:primitive)GLContractFeedbackVertex(ctx,v);
        }
    });
    return true;
}
// RasterPos stores window coordinates and attributes at the time it is set.
// Pixel operations consume those values directly rather than transforming them
// through the current matrices or depth range a second time.
static inline bool GLProcessRasterRenderMode(GLContext *ctx,uint32_t token)
{
    if(ctx->render_mode!=0x1c01 && ctx->render_mode!=0x1c02)return false;
    if(!ctx->raster_pos_valid)return true;
    if(ctx->render_mode==0x1c02) {
        GLSelectionRecordDepthRange(ctx,ctx->raster_pos[2],ctx->raster_pos[2]);
        return true;
    }
    GLFeedbackWrite(ctx,float(token));
    GLFeedbackWrite(ctx,ctx->raster_pos[0]);GLFeedbackWrite(ctx,ctx->raster_pos[1]);
    if(ctx->feedback_type!=0x0600)GLFeedbackWrite(ctx,ctx->raster_pos[2]);
    if(ctx->feedback_type==0x0604)GLFeedbackWrite(ctx,ctx->raster_pos[3]);
    if(ctx->feedback_type>=0x0602)for(float color:ctx->raster_color)GLFeedbackWrite(ctx,color);
    if(ctx->feedback_type>=0x0603)for(float coordinate:ctx->raster_texcoord)GLFeedbackWrite(ctx,coordinate);
    return true;
}
#endif
