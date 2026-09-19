#import "FXRuntime.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
unsigned checks=0;
constexpr NSUInteger width=16,height=12,depthWidth=8,depthHeight=6;
void Check(bool condition,const char *message) {
    ++checks;
    if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
id<MTLTexture> Texture(id<MTLDevice> device,MTLPixelFormat format,NSUInteger w,NSUInteger h,
                       MTLTextureUsage usage=MTLTextureUsageShaderRead) {
    auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=usage;
    return [device newTextureWithDescriptor:descriptor];
}
std::vector<float> DepthValues(float offset) {
    std::vector<float> result(depthWidth*depthHeight);
    for(NSUInteger y=0;y<depthHeight;++y)for(NSUInteger x=0;x<depthWidth;++x)
        result[y*depthWidth+x]=offset+0.45f*x/(depthWidth-1)+0.30f*y/(depthHeight-1);
    return result;
}
void UploadDepth(id<MTLTexture> texture,const std::vector<float> &values) {
    [texture replaceRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0 withBytes:values.data() bytesPerRow:texture.width*sizeof(float)];
}
std::vector<uint8_t> ReadColor(id<MTLTexture> texture) {
    std::vector<uint8_t> result(texture.width*texture.height*4);
    [texture getBytes:result.data() bytesPerRow:texture.width*4 fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];
    return result;
}
bool Render(MSFXEffect *effect,id<MTLCommandQueue> queue,id<MTLTexture> color,id<MTLTexture> depth) {
    auto buffer=[queue commandBufferWithUnretainedReferences];NSError *error=nil;
    if(![effect encodeCommandBuffer:buffer texture:color depthTexture:depth time:1 error:&error]) {
        fprintf(stderr,"Depth encode: %s\n",error.localizedDescription.UTF8String);return false;
    }
    [buffer commit];[buffer waitUntilCompleted];
    if(buffer.error)fprintf(stderr,"Depth GPU: %s\n",buffer.error.localizedDescription.UTF8String);
    return buffer.status==MTLCommandBufferStatusCompleted;
}
bool MatchesDepth(const std::vector<uint8_t> &color,const std::vector<float> &depth) {
    for(NSUInteger y=0;y<height;++y)for(NSUInteger x=0;x<width;++x) {
        const float value=depth[(y*depthHeight/height)*depthWidth+(x*depthWidth/width)];
        const size_t index=(y*width+x)*4;
        if(std::abs(int(color[index])-int(std::lround(value*255)))>1 ||
           std::abs(int(color[index+1])-int(std::lround((1-value)*255)))>1 || color[index+3]!=255)return false;
    }
    return true;
}
}

int main(int argc,const char *argv[]) { @autoreleasepool {
    auto device=MTLCreateSystemDefaultDevice();Check(device!=nil,"Metal device is available");
    auto queue=[device newCommandQueue];
    auto color=Texture(device,MTLPixelFormatRGBA8Unorm,width,height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
    auto depth=Texture(device,MTLPixelFormatR32Float,depthWidth,depthHeight);
    Check(queue&&color&&depth,"color and differently sized R32Float depth textures allocate");
    std::vector<uint8_t> initial(width*height*4,80);
    for(size_t i=3;i<initial.size();i+=4)initial[i]=255;
    [color replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:initial.data() bytesPerRow:width*4];
    auto values=DepthValues(0.05f);UploadDepth(depth,values);

    NSString *source=@"#if RESHADE_DEPTH_INPUT_IS_REVERSED != 0\n#error Expected normalized depth convention\n#endif\n"
        "texture2D SceneDepth : DEPTH; texture2D SceneColor : COLOR;\n"
        "sampler2D DepthSampler {Texture=SceneDepth;MinFilter=POINT;MagFilter=POINT;MipFilter=POINT;};\n"
        "sampler2D ColorSampler {Texture=SceneColor;};\n"
        "void VS(uint id:SV_VertexID,out float4 p:SV_Position,out float2 uv:TEXCOORD0){uv=float2((id<<1)&2,id&2);p=float4(uv*float2(2,-2)+float2(-1,1),0,1);}\n"
        "float4 DepthPS(float4 p:SV_Position,float2 uv:TEXCOORD0):SV_Target{float d=tex2D(DepthSampler,uv).r;return float4(d,1-d,uv.x,1);}\n"
        "float4 ColorPS(float4 p:SV_Position,float2 uv:TEXCOORD0):SV_Target{return tex2D(ColorSampler,uv);}\n"
        "technique Visualize {pass {VertexShader=VS;PixelShader=DepthPS;}}\n"
        "technique Copy {pass {VertexShader=VS;PixelShader=ColorPS;}}\n";
    NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [[@"macshade-depth-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:@"fx"]]];
    NSError *error=nil;
    Check([source writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error],"depth fixture writes");
    MSFXEffect *effect=[[MSFXEffect alloc]initWithURL:file device:device width:width height:height error:&error];
    if(!effect)fprintf(stderr,"Depth compile: %s\n",error.localizedDescription.UTF8String);
    Check(effect&&effect.requiresDepth,"DEPTH shader compiles and advertises its input requirement");
    Check([NSFileManager.defaultManager removeItemAtURL:file error:&error],"temporary shader source is removed");

    error=nil;
    Check(![effect encodeCommandBuffer:[queue commandBuffer] texture:color time:0 error:&error]&&
          [error.localizedDescription containsString:@"R32Float"],"legacy encode rejects missing depth with an actionable diagnostic");
    Check(ReadColor(color)==initial,"missing depth leaves color unchanged");
    Check(Render(effect,queue,color,depth),"depth shader encodes with an unretained-reference command buffer");
    Check(MatchesDepth(ReadColor(color),values),"known depth data preserves orientation at a different input resolution");

    auto replacement=Texture(device,MTLPixelFormatR32Float,depthWidth,depthHeight);
    auto newValues=DepthValues(0.15f);UploadDepth(replacement,newValues);
    Check(Render(effect,queue,color,replacement)&&MatchesDepth(ReadColor(color),newValues),"each frame samples the newly supplied depth texture");

    auto badFormat=Texture(device,MTLPixelFormatR16Float,depthWidth,depthHeight);
    error=nil;
    Check(![effect encodeCommandBuffer:[queue commandBuffer] texture:color depthTexture:badFormat time:0 error:&error]&&
          [error.localizedDescription containsString:@"R32Float"],"non-R32Float depth is rejected before encoding");
    auto unreadable=Texture(device,MTLPixelFormatR32Float,depthWidth,depthHeight,MTLTextureUsageRenderTarget);
    error=nil;
    Check(![effect encodeCommandBuffer:[queue commandBuffer] texture:color depthTexture:unreadable time:0 error:&error]&&
          [error.localizedDescription containsString:@"shader-read"],"depth without shader-read usage is rejected");
    if([device supportsTextureSampleCount:4]) {
        auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:depthWidth height:depthHeight mipmapped:NO];
        descriptor.textureType=MTLTextureType2DMultisample;descriptor.sampleCount=4;
        descriptor.storageMode=MTLStorageModePrivate;descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        auto multisampled=[device newTextureWithDescriptor:descriptor];
        Check(multisampled!=nil,"multisampled rejection fixture allocates");error=nil;
        Check(![effect encodeCommandBuffer:[queue commandBuffer] texture:color depthTexture:multisampled time:0 error:&error]&&
              [error.localizedDescription containsString:@"single-sample"],"multisampled depth must be resolved before effects");
    }
    Check([effect selectTechniqueNamed:@"Copy" error:&error]&&!effect.requiresDepth,"depth requirement follows the selected technique only");
    auto before=ReadColor(color);
    Check(Render(effect,queue,color,nil)&&ReadColor(color)==before,"unused depth declaration does not block a color-only technique");

    NSURL *ssrFile = argc > 1 ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] :
        [NSURL fileURLWithPath:@"Effects/qUINT/qUINT_ssr.fx"];
    if ([NSFileManager.defaultManager fileExistsAtPath:ssrFile.path]) {
        MSFXEffect *ssr=[[MSFXEffect alloc]initWithURL:ssrFile device:device width:width height:height error:&error];
        if(!ssr)fprintf(stderr,"External depth effect compile: %s\n",error.localizedDescription.UTF8String);
        Check(ssr&&ssr.requiresDepth,"external depth effect compiles with its real include files");
        Check(Render(ssr,queue,color,replacement),"external depth effect completes its real multipass GPU workload");
    }
    printf("PASS: %u depth GPU checks on %s\n",checks,device.name.UTF8String);return 0;
}}
