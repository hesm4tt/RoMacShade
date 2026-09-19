//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "Obfuscate.h"
#import "FXRuntime.h"
#include "FXCompiler.hpp"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <cmath>
#include <cstring>
#include <mutex>
#include <memory>
#include <algorithm>
#include <set>
#include <vector>
#include <unordered_map>

namespace {
using namespace reshadefx;
NSString *S(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }
BOOL Fail(NSError **error, NSString *text) {
    if (error) *error=[NSError errorWithDomain:@"MacShade.FX" code:1 userInfo:@{NSLocalizedDescriptionKey:text ?: @"FX error"}];
    return NO;
}
MTLPixelFormat Format(texture_format f) {
    switch(f) {
        case texture_format::r8:return MTLPixelFormatR8Unorm;
        case texture_format::r16f:return MTLPixelFormatR16Float;
        case texture_format::r16:return MTLPixelFormatR16Unorm;
        case texture_format::r32f:return MTLPixelFormatR32Float;
        case texture_format::rg8:return MTLPixelFormatRG8Unorm;
        case texture_format::rg16f:return MTLPixelFormatRG16Float;
        case texture_format::rg16:return MTLPixelFormatRG16Unorm;
        case texture_format::rg32f:return MTLPixelFormatRG32Float;
        case texture_format::rgba8:return MTLPixelFormatRGBA8Unorm;
        case texture_format::rgba16f:return MTLPixelFormatRGBA16Float;
        case texture_format::rgba16:return MTLPixelFormatRGBA16Unorm;
        case texture_format::rgba32f:return MTLPixelFormatRGBA32Float;
        case texture_format::rgb10a2:return MTLPixelFormatRGB10A2Unorm;
        case texture_format::rg11b10f:return MTLPixelFormatRG11B10Float;
        default:return MTLPixelFormatInvalid;
    }
}
MTLPixelFormat SRGB(MTLPixelFormat f) {
    if(f==MTLPixelFormatRGBA8Unorm)return MTLPixelFormatRGBA8Unorm_sRGB;
    if(f==MTLPixelFormatBGRA8Unorm)return MTLPixelFormatBGRA8Unorm_sRGB;
    return f;
}
MTLPixelFormat Linear(MTLPixelFormat f) {
    if(f==MTLPixelFormatRGBA8Unorm_sRGB)return MTLPixelFormatRGBA8Unorm;
    if(f==MTLPixelFormatBGRA8Unorm_sRGB)return MTLPixelFormatBGRA8Unorm;
    return f;
}
MTLBlendFactor Blend(blend_factor f) {
    switch(f) {
        case blend_factor::zero:return MTLBlendFactorZero;
        case blend_factor::one:return MTLBlendFactorOne;
        case blend_factor::source_color:return MTLBlendFactorSourceColor;
        case blend_factor::one_minus_source_color:return MTLBlendFactorOneMinusSourceColor;
        case blend_factor::dest_color:return MTLBlendFactorDestinationColor;
        case blend_factor::one_minus_dest_color:return MTLBlendFactorOneMinusDestinationColor;
        case blend_factor::source_alpha:return MTLBlendFactorSourceAlpha;
        case blend_factor::one_minus_source_alpha:return MTLBlendFactorOneMinusSourceAlpha;
        case blend_factor::dest_alpha:return MTLBlendFactorDestinationAlpha;
        case blend_factor::one_minus_dest_alpha:return MTLBlendFactorOneMinusDestinationAlpha;
    }
}
MTLBlendOperation BlendOp(blend_op f) {
    switch(f) {
        case blend_op::add:return MTLBlendOperationAdd;
        case blend_op::subtract:return MTLBlendOperationSubtract;
        case blend_op::reverse_subtract:return MTLBlendOperationReverseSubtract;
        case blend_op::min:return MTLBlendOperationMin;
        case blend_op::max:return MTLBlendOperationMax;
    }
}
MTLSamplerAddressMode Address(texture_address_mode v) {
    switch(v) {
        case texture_address_mode::wrap:return MTLSamplerAddressModeRepeat;
        case texture_address_mode::mirror:return MTLSamplerAddressModeMirrorRepeat;
        case texture_address_mode::clamp:return MTLSamplerAddressModeClampToEdge;
        case texture_address_mode::border:return MTLSamplerAddressModeClampToBorderColor;
    }
}
MTLPrimitiveType Primitive(primitive_topology p) {
    switch(p) {
        case primitive_topology::point_list:return MTLPrimitiveTypePoint;
        case primitive_topology::line_list:return MTLPrimitiveTypeLine;
        case primitive_topology::line_strip:return MTLPrimitiveTypeLineStrip;
        case primitive_topology::triangle_list:return MTLPrimitiveTypeTriangle;
        case primitive_topology::triangle_strip:return MTLPrimitiveTypeTriangleStrip;
    }
}
std::string Annotation(const std::vector<annotation>& annotations, const char *name) {
    for(const auto &a:annotations)if(a.name==name)return a.value.string_data;
    return {};
}
bool IsDepth(const texture &value) {
    return [S(value.semantic) caseInsensitiveCompare:@"DEPTH"]==NSOrderedSame;
}
NSArray<NSNumber *> *UniformValues(const uniform &value, const std::vector<uint8_t> &bytes) {
    NSMutableArray<NSNumber *> *result=[NSMutableArray array];
    for(unsigned i=0;i<value.type.components();++i) {
        const uint8_t *p=bytes.data()+value.offset+i*4;
        if(value.type.is_floating_point()){float number;memcpy(&number,p,4);[result addObject:@(number)];}
        else if(value.type.is_signed()){int32_t number;memcpy(&number,p,4);[result addObject:@(number)];}
        else {uint32_t number;memcpy(&number,p,4);[result addObject:@(number)];}
    }
    return [result copy];
}
id NumericAnnotation(const std::vector<annotation> &annotations, const char *name) {
    for(const auto &a:annotations)if(a.name==name&&a.type.is_numeric()) {
        NSMutableArray<NSNumber *> *numbers=[NSMutableArray array];
        const auto append=[&](const constant &value)->bool {
            for(unsigned i=0;i<a.type.components();++i) {
                if(a.type.is_floating_point()) {
                    if(!std::isfinite(value.as_float[i]))return false;
                    [numbers addObject:@(value.as_float[i])];
                } else if(a.type.is_signed())[numbers addObject:@(value.as_int[i])];
                else [numbers addObject:@(value.as_uint[i])];
            }
            return true;
        };
        if(a.type.is_array()){for(const auto &value:a.value.array_data)if(!append(value))return nil;}
        else if(!append(a.value))return nil;
        if(numbers.count==0)return nil;
        return numbers.count==1?numbers[0]:[numbers copy];
    }
    return nil;
}
NSArray<NSString *> *UIItems(const std::vector<annotation> &annotations) {
    const std::string items=Annotation(annotations,"ui_items");
    NSMutableArray<NSString *> *result=[NSMutableArray array];
    size_t start=0;
    while(start<items.size()) {
        size_t end=items.find('\0',start);
        if(end==std::string::npos)end=items.size();
        NSString *item=[[NSString alloc] initWithBytes:items.data()+start length:end-start encoding:NSUTF8StringEncoding];
        [result addObject:item?:@""];
        start=end+1;
    }
    return [result copy];
}
id<MTLTexture> NewTexture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger w, NSUInteger h, NSUInteger levels=1) {
    NSUInteger maxLevels = 1 + (NSUInteger)std::floor(std::log2(std::max(w, h)));
    NSUInteger clampedLevels = std::min(levels, maxLevels);
    if (clampedLevels == 0) clampedLevels = 1;
    auto *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:clampedLevels>1];
    d.mipmapLevelCount=clampedLevels;d.storageMode=MTLStorageModePrivate;
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
    return [device newTextureWithDescriptor:d];
}

struct ScratchPoolKey {
    MTLPixelFormat format;
    NSUInteger width;
    NSUInteger height;
    NSUInteger levels;
    bool operator==(const ScratchPoolKey &o) const {
        return format == o.format && width == o.width && height == o.height && levels == o.levels;
    }
};

struct ScratchPoolKeyHash {
    std::size_t operator()(const ScratchPoolKey &k) const {
        std::size_t h = (std::size_t)k.format;
        h ^= (k.width << 16) | (k.width >> 16);
        h ^= (k.height << 8) | (k.height >> 24);
        h ^= (k.levels << 28);
        return h;
    }
};

class ScratchTexturePool {
    std::mutex _mutex;
    std::unordered_map<ScratchPoolKey, std::vector<id<MTLTexture>>, ScratchPoolKeyHash> _idle;
public:
    static ScratchTexturePool &shared() {
        static ScratchTexturePool instance;
        return instance;
    }
    id<MTLTexture> acquire(id<MTLDevice> device, MTLPixelFormat format, NSUInteger w, NSUInteger h, NSUInteger levels = 1) {
        if (!device || !w || !h) return nil;
        ScratchPoolKey key{format, w, h, levels};
        {
            std::lock_guard<std::mutex> lock(_mutex);
            auto it = _idle.find(key);
            if (it != _idle.end() && !it->second.empty()) {
                id<MTLTexture> tex = it->second.back();
                it->second.pop_back();
                return tex;
            }
        }
        return NewTexture(device, format, w, h, levels);
    }
    void release(id<MTLTexture> tex, id<MTLCommandBuffer> buffer) {
        if (!tex || !buffer) return;
        ScratchPoolKey key{tex.pixelFormat, tex.width, tex.height, tex.mipmapLevelCount};
        [buffer addCompletedHandler:^(id<MTLCommandBuffer>){
            auto &pool = ScratchTexturePool::shared();
            std::lock_guard<std::mutex> lock(pool._mutex);
            auto &list = pool._idle[key];
            if (list.size() < 16) {
                list.push_back(tex);
            }
        }];
    }
};
} // anonymous namespace

id<MTLTexture> MSAcquireScratchTexture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width, NSUInteger height, NSUInteger levels) {
    return ScratchTexturePool::shared().acquire(device, format, width, height, levels);
}

void MSRecycleScratchTexture(id<MTLTexture> texture, id<MTLCommandBuffer> buffer) {
    ScratchTexturePool::shared().release(texture, buffer);
}

namespace {
void Blit(id<MTLCommandBuffer> buffer,id<MTLTexture> from,id<MTLTexture> to) {
    auto blit=[buffer blitCommandEncoder];
    for(NSUInteger level=0;level<from.mipmapLevelCount;++level)
        [blit copyFromTexture:from sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(std::max(NSUInteger(1),from.width>>level),std::max(NSUInteger(1),from.height>>level),1)
            toTexture:to destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
}
void Clear(id<MTLCommandBuffer> buffer,id<MTLTexture> target) {
    for(NSUInteger level=0;level<target.mipmapLevelCount;++level) {
        auto *d=[MTLRenderPassDescriptor renderPassDescriptor];
        d.colorAttachments[0].texture=target;d.colorAttachments[0].level=level;
        d.colorAttachments[0].loadAction=MTLLoadActionClear;d.colorAttachments[0].storeAction=MTLStoreActionStore;
        [[buffer renderCommandEncoderWithDescriptor:d] endEncoding];
    }
}
const char *copyMSL=R"metal(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position [[position]]; };
vertex V copyVS(uint i [[vertex_id]]) {
    float2 p=float2((i<<1)&2,i&2)*2.0-1.0;return {float4(p,0,1)};
}
fragment float4 copyPS(V v [[stage_in]],texture2d<float> t [[texture(0)]]) { return t.read(uint2(v.position.xy)); }
)metal";

NSURL *FindImageFile(NSString *sourceName, NSURL *effectURL, NSArray<NSURL *> *includeDirectories) {
    if (!sourceName.length) return nil;
    NSString *clean = [sourceName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *base = clean.lastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    
    NSMutableArray<NSURL *> *dirs = [NSMutableArray array];
    NSURL *effectDir = effectURL.URLByDeletingLastPathComponent;
    if (effectDir) {
        [dirs addObject:effectDir];
        [dirs addObject:[effectDir URLByAppendingPathComponent:@"Textures"]];
        [dirs addObject:[effectDir URLByAppendingPathComponent:@"reshade-shaders/Textures"]];
        NSURL *parent = effectDir.URLByDeletingLastPathComponent;
        if (parent) {
            [dirs addObject:[parent URLByAppendingPathComponent:@"Textures"]];
            [dirs addObject:[parent URLByAppendingPathComponent:@"reshade-shaders/Textures"]];
        }
    }
    for (NSURL *inc in includeDirectories) {
        [dirs addObject:inc];
        [dirs addObject:[inc URLByAppendingPathComponent:@"Textures"]];
        [dirs addObject:[inc URLByAppendingPathComponent:@"reshade-shaders/Textures"]];
        NSURL *parent = inc.URLByDeletingLastPathComponent;
        if (parent) {
            [dirs addObject:[parent URLByAppendingPathComponent:@"Textures"]];
            [dirs addObject:[parent URLByAppendingPathComponent:@"reshade-shaders/Textures"]];
        }
    }
    
    for (NSURL *dir in dirs) {
        NSURL *cand = [dir URLByAppendingPathComponent:clean];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:cand.path isDirectory:&isDir] && !isDir) return cand;
    }
    for (NSURL *dir in dirs) {
        NSURL *cand = [dir URLByAppendingPathComponent:base];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:cand.path isDirectory:&isDir] && !isDir) return cand;
    }
    for (NSURL *dir in dirs) {
        if (![dir.lastPathComponent isEqualToString:@"Textures"]) continue;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:dir includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *fileURL in enumerator) {
            if ([fileURL.lastPathComponent caseInsensitiveCompare:base] == NSOrderedSame) {
                return fileURL;
            }
        }
    }
    return nil;
}

id<MTLTexture> LoadImageTexture(id<MTLDevice> device, NSURL *url, MTLPixelFormat desiredFormat,
                                NSUInteger width, NSUInteger height, NSUInteger levels) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return nil;
    
    size_t imgWidth = CGImageGetWidth(image);
    size_t imgHeight = CGImageGetHeight(image);
    size_t texWidth = (width > 0) ? width : imgWidth;
    size_t texHeight = (height > 0) ? height : imgHeight;
    if (texWidth == 0 || texHeight == 0) {
        CGImageRelease(image);
        return nil;
    }
    
    size_t bytesPerRow = texWidth * 4;
    size_t dataSize = bytesPerRow * texHeight;
    std::vector<uint8_t> pixelData(dataSize, 0);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixelData.data(), texWidth, texHeight, 8, bytesPerRow,
                                                colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    
    if (!context) {
        CGImageRelease(image);
        return nil;
    }
    
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, texWidth, texHeight), image);
    CGContextRelease(context);
    CGImageRelease(image);
    
    MTLPixelFormat finalFormat = (desiredFormat != MTLPixelFormatInvalid) ? desiredFormat : MTLPixelFormatRGBA8Unorm;
    NSUInteger mipCount = (levels > 0) ? levels : 1;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:finalFormat
                                                                                     width:texWidth
                                                                                    height:texHeight
                                                                                 mipmapped:(mipCount > 1)];
    desc.mipmapLevelCount = mipCount;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) return nil;
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) return nil;
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    if (!cmd) return nil;
    
    if (finalFormat == MTLPixelFormatR8Unorm) {
        size_t rBytesPerRow = texWidth;
        std::vector<uint8_t> rData(rBytesPerRow * texHeight);
        for (size_t i = 0; i < texWidth * texHeight; ++i) {
            rData[i] = pixelData[i * 4];
        }
        id<MTLBuffer> staging = [device newBufferWithBytes:rData.data() length:rData.size() options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:rBytesPerRow sourceBytesPerImage:rData.size()
                  sourceSize:MTLSizeMake(texWidth, texHeight, 1)
                   toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        if (texture.mipmapLevelCount > 1) {
            [blit generateMipmapsForTexture:texture];
        }
        [blit endEncoding];
    } else if (finalFormat == MTLPixelFormatRG8Unorm) {
        size_t rgBytesPerRow = texWidth * 2;
        std::vector<uint8_t> rgData(rgBytesPerRow * texHeight);
        for (size_t i = 0; i < texWidth * texHeight; ++i) {
            rgData[i * 2 + 0] = pixelData[i * 4 + 0];
            rgData[i * 2 + 1] = pixelData[i * 4 + 1];
        }
        id<MTLBuffer> staging = [device newBufferWithBytes:rgData.data() length:rgData.size() options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:rgBytesPerRow sourceBytesPerImage:rgData.size()
                  sourceSize:MTLSizeMake(texWidth, texHeight, 1)
                   toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        if (texture.mipmapLevelCount > 1) {
            [blit generateMipmapsForTexture:texture];
        }
        [blit endEncoding];
    } else {
        id<MTLBuffer> staging = [device newBufferWithBytes:pixelData.data() length:dataSize options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:bytesPerRow sourceBytesPerImage:dataSize
                  sourceSize:MTLSizeMake(texWidth, texHeight, 1)
                   toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        if (texture.mipmapLevelCount > 1) {
            [blit generateMipmapsForTexture:texture];
        }
        [blit endEncoding];
    }
    
    [cmd commit];
    [cmd waitUntilCompleted];
    return texture;
}

}

@interface MSFXFrameResources : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *,id<MTLTexture>> *textures;
@property(nonatomic, strong) NSDictionary<NSString *,id<MTLTexture>> *previous;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) BOOL initialized;
@end
@implementation MSFXFrameResources
@end

namespace {
struct FXResourceState {
    std::mutex lock;
    NSMapTable<id<MTLCommandBuffer>,MSFXFrameResources *> *__strong frames=[NSMapTable weakToStrongObjectsMapTable];
    NSDictionary<NSString *,id<MTLTexture>> *__strong history=@{};
    uint64_t nextSequence=0,completedSequence=0;
};
}

@implementation MSFXEffect {
    id<MTLDevice> _device;
    macshade::FXProgram _program;
    NSMutableDictionary<NSString *,id<MTLFunction>> *_functions;
    NSMutableArray<NSArray<id<MTLRenderPipelineState>> *> *_pipelines;
    NSMutableArray<id<MTLSamplerState>> *_samplers;
    id<MTLLibrary> _copyLibrary;
    NSMutableDictionary<NSNumber *,id<MTLRenderPipelineState>> *_copyPipelines;
    NSMutableDictionary<NSString *,id<MTLTexture>> *_staticTextures;
    std::shared_ptr<FXResourceState> _resourceState;
    NSDictionary *_sourceConfiguration;
    std::set<std::string> _persistentTextureNames;
    std::mutex _lock;
    std::vector<uint8_t> _uniformData;
    std::vector<bool> _techniqueRequiresDepth;
    NSUInteger _selected;
    uint64_t _frame;
    double _previousTime;
}

- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error {
    return [self initWithURL:url device:device width:width height:height definitions:@{} includeDirectories:@[] error:error];
}

- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height
                definitions:(NSDictionary<NSString *,NSString *> *)definitions includeDirectories:(NSArray<NSURL *> *)includeDirectories
                      error:(NSError **)error {
    if(error)*error=nil;
    if(!(self=[super init]))return nil;
    if(!device||!url.isFileURL||!width||!height||width>16384||height>16384) {
        Fail(error,@"An effect file, Metal device, and frame dimensions within 1…16384 are required.");return nil;
    }
    _device=device;_selected=0;_frame=0;_previousTime=0;
    macshade::FXCompileOptions options; options.width=(uint32_t)width;options.height=(uint32_t)height;
    NSDictionary *definitionSnapshot=[definitions copy];
    for(id name in definitionSnapshot) {
        id value=definitionSnapshot[name];
        if(![name isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class]||[name length]==0) {
            Fail(error,@"FX definitions require nonempty string names and string values.");return nil;
        }
        options.definitions[[name UTF8String]]=[value UTF8String];
    }
    for(id directory in [includeDirectories copy]) {
        if(![directory isKindOfClass:NSURL.class]||![directory isFileURL]) {
            Fail(error,@"FX include directories must be local file URLs.");return nil;
        }
        options.includeDirectories.emplace_back([directory fileSystemRepresentation]);
    }
    std::string diagnostic;
    if(!macshade::CompileFXFile(url.fileSystemRepresentation,options,_program,diagnostic)) {Fail(error,S(diagnostic));return nil;}
    if(_program.module.techniques.empty()){Fail(error,@"The FX file has no techniques.");return nil;}
    _uniformData=_program.defaultUniformData;
    _staticTextures=[NSMutableDictionary dictionary];
    _resourceState=std::make_shared<FXResourceState>();
    _sourceConfiguration=@{@"url":url.URLByStandardizingPath, @"definitions":definitionSnapshot, @"includes":[includeDirectories copy]};
    for(const auto &u:_program.module.uniforms) {
        if(u.type.is_array()||u.type.is_matrix()||!u.type.is_numeric()) {
            Fail(error,[NSString stringWithFormat:@"Uniform %@ uses an unsupported array, matrix or object type.",S(u.name)]);return nil;
        }
        if(u.offset+u.type.components()*4>_uniformData.size()){Fail(error,@"Invalid reflected uniform layout.");return nil;}
    }
    uint64_t pixels=uint64_t(width)*height*3;
    for(auto &t:_program.module.textures) {
        if(!t.semantic.empty())continue; // Compiler validates active external semantics.
        std::string source=Annotation(t.annotations,"source");
        if(!source.empty()) {
            NSURL *imgURL=FindImageFile(S(source),url,includeDirectories);
            id<MTLTexture> imgTex=nil;
            if(imgURL) {
                imgTex=LoadImageTexture(device,imgURL,Format(t.format),t.width,t.height,t.levels);
            }
            if(!imgTex) {
                imgTex=NewTexture(device,Format(t.format),t.width,t.height,t.levels);
            }
            if(imgTex) {
                _staticTextures[S(t.unique_name)]=imgTex;
            }
            continue;
        }
        if(t.type!=texture_type::texture_2d||t.width==0||t.height==0||t.width>16384||t.height>16384||!t.levels||Format(t.format)==MTLPixelFormatInvalid) {
            Fail(error,[NSString stringWithFormat:@"Texture %@ has unsupported dimensions, type or format.",S(t.name)]);return nil;
        }
        uint32_t maxLevels = 1 + (uint32_t)std::floor(std::log2(std::max(t.width, t.height)));
        if(t.levels > maxLevels) t.levels = maxLevels;
        pixels+=uint64_t(t.width)*t.height*2;
    }
    if(pixels>512ull*1024*1024){Fail(error,@"The effect's per-frame texture allocation exceeds this prototype's limit.");return nil;}
    _functions=[NSMutableDictionary dictionary];_pipelines=[NSMutableArray array];_samplers=[NSMutableArray array];
    _copyPipelines=[NSMutableDictionary dictionary];
    MTLCompileOptions *compileOptions=[MTLCompileOptions new];compileOptions.fastMathEnabled=NO;
    for(const auto &[name,entry]:_program.entryPoints) {
        for(const auto &binding:entry.sampledBindings)if(binding.samplerSlot>=16||binding.textureSlot>=128) {
            Fail(error,@"The effect exceeds the supported Metal resource slot count.");return nil;
        }
        auto library=[device newLibraryWithSource:S(entry.metalSource) options:compileOptions error:error];
        if(!library)return nil;
        auto function=[library newFunctionWithName:S(entry.metalName)];
        if(!function){Fail(error,[NSString stringWithFormat:@"Metal entry point %@ is missing.",S(entry.metalName)]);return nil;}
        _functions[S(name)]=function;
    }
    _copyLibrary=[device newLibraryWithSource:[NSString stringWithUTF8String:copyMSL] options:compileOptions error:error];
    if(!_copyLibrary)return nil;
    for(const auto &s:_program.module.samplers) {
        if(s.lod_bias!=0){Fail(error,@"Sampler LOD bias is not implemented.");return nil;}
        auto *d=[MTLSamplerDescriptor new];unsigned f=(unsigned)s.filter;
        d.minFilter=(f&0x10)?MTLSamplerMinMagFilterLinear:MTLSamplerMinMagFilterNearest;
        d.magFilter=(f&0x4)?MTLSamplerMinMagFilterLinear:MTLSamplerMinMagFilterNearest;
        d.mipFilter=(f&0x1)?MTLSamplerMipFilterLinear:MTLSamplerMipFilterNearest;
        d.maxAnisotropy=s.filter==filter_mode::anisotropic?16:1;
        d.sAddressMode=Address(s.address_u);d.tAddressMode=Address(s.address_v);d.rAddressMode=Address(s.address_w);
        d.lodMinClamp=std::max(0.0f,s.min_lod);d.lodMaxClamp=std::max(d.lodMinClamp,s.max_lod);
        auto sampler=[device newSamplerStateWithDescriptor:d];
        if(!sampler){Fail(error,@"Metal could not create an FX sampler.");return nil;}[_samplers addObject:sampler];
    }
    for(const auto &technique:_program.module.techniques) {
        NSMutableArray *pipelines=[NSMutableArray array];
        std::set<std::string> written;
        bool requiresDepth=false;
        for(const auto &pass:technique.passes) {
            if(!pass.cs_entry_point.empty()||!pass.storage_bindings.empty()) {Fail(error,@"Compute and storage passes are not supported.");return nil;}
            for(const auto &entryName:{pass.vs_entry_point,pass.ps_entry_point}) {
                auto entry=_program.entryPoints.find(entryName);
                if(entry==_program.entryPoints.end()){Fail(error,@"A pass entry point is missing.");return nil;}
                for(const auto &binding:entry->second.sampledBindings) {
                    const auto &t=_program.module.textures[binding.textureIndex];
                    if(IsDepth(t))requiresDepth=true;
                    if(t.semantic.empty()&&!written.count(t.unique_name)) {
                        if(_staticTextures[S(t.unique_name)] != nil) {
                            // Loaded static image asset
                        } else {
                            // Temporal history texture
                            _persistentTextureNames.insert(t.unique_name);
                        }
                    }
                }
            }
            auto *d=[MTLRenderPipelineDescriptor new];d.label=S(technique.name+" / "+pass.name);
            d.vertexFunction=_functions[S(pass.vs_entry_point)];d.fragmentFunction=_functions[S(pass.ps_entry_point)];
            if(!d.vertexFunction||!d.fragmentFunction){Fail(error,@"A raster pass is missing its vertex or pixel shader.");return nil;}
            bool implicit=pass.render_target_names[0].empty();
            uint32_t targetWidth=0,targetHeight=0;
            for(unsigned i=0;i<8;++i) {
                MTLPixelFormat format=MTLPixelFormatInvalid;
                if(implicit&&i==0){format=MTLPixelFormatRGBA8Unorm;targetWidth=(uint32_t)width;targetHeight=(uint32_t)height;}
                else if(!pass.render_target_names[i].empty()) {
                    auto found=std::find_if(_program.module.textures.begin(),_program.module.textures.end(),[&](const texture &t){return t.unique_name==pass.render_target_names[i];});
                    if(found==_program.module.textures.end()||!found->semantic.empty()){Fail(error,@"Render target is missing or aliases an external texture.");return nil;}
                    format=Format(found->format);
                    if(targetWidth&&(targetWidth!=found->width||targetHeight!=found->height)){Fail(error,@"Multiple render targets must have matching dimensions.");return nil;}
                    targetWidth=found->width;targetHeight=found->height;
                } else continue;
                if(pass.srgb_write_enable&&SRGB(format)==format){Fail(error,@"sRGB writing requires an RGBA8 render target.");return nil;}
                auto a=d.colorAttachments[i];a.pixelFormat=pass.srgb_write_enable?SRGB(format):format;
                a.blendingEnabled=pass.blend_enable[i];a.sourceRGBBlendFactor=Blend(pass.source_color_blend_factor[i]);
                a.destinationRGBBlendFactor=Blend(pass.dest_color_blend_factor[i]);a.rgbBlendOperation=BlendOp(pass.color_blend_op[i]);
                a.sourceAlphaBlendFactor=Blend(pass.source_alpha_blend_factor[i]);a.destinationAlphaBlendFactor=Blend(pass.dest_alpha_blend_factor[i]);
                a.alphaBlendOperation=BlendOp(pass.alpha_blend_op[i]);
                unsigned mask=pass.render_target_write_mask[i];
                const auto &componentMap=_program.entryPoints.at(pass.ps_entry_point).outputComponents;
                auto components=componentMap.find(i);
                if(components!=componentMap.end()&&components->second<4)mask&=(1u<<components->second)-1u;
                // Metal requires padded shader outputs; retain destination
                // channels the FX shader did not actually write (notably alpha).
                a.writeMask=(MTLColorWriteMask)(((mask&1)?MTLColorWriteMaskRed:0)|((mask&2)?MTLColorWriteMaskGreen:0)|((mask&4)?MTLColorWriteMaskBlue:0)|((mask&8)?MTLColorWriteMaskAlpha:0));
            }
            if((pass.viewport_width&&pass.viewport_width>targetWidth)||(pass.viewport_height&&pass.viewport_height>targetHeight)){Fail(error,@"Pass viewport exceeds its render target.");return nil;}
            auto pipeline=[device newRenderPipelineStateWithDescriptor:d error:error];if(!pipeline)return nil;
            [pipelines addObject:pipeline];
            for(const auto &name:pass.render_target_names)if(!name.empty())written.insert(name);
        }
        [_pipelines addObject:pipelines];
        _techniqueRequiresDepth.push_back(requiresDepth);
    }
    return self;
}

- (NSUInteger)width { return _program.width; }
- (NSUInteger)height { return _program.height; }
- (NSArray<NSString *> *)techniqueNames {
    NSMutableArray *names=[NSMutableArray array];for(const auto &t:_program.module.techniques)[names addObject:S(t.name)];return names;
}
- (NSString *)activeTechnique {std::lock_guard<std::mutex> lock(_lock);return S(_program.module.techniques[_selected].name);}
- (BOOL)requiresDepth {std::lock_guard<std::mutex> lock(_lock);return _techniqueRequiresDepth[_selected];}
- (BOOL)selectTechniqueNamed:(NSString *)name error:(NSError **)error {
    if(error)*error=nil;std::lock_guard<std::mutex> lock(_lock);
    for(size_t i=0;i<_program.module.techniques.size();++i)if(S(_program.module.techniques[i].name).length&&[S(_program.module.techniques[i].name) isEqualToString:name]){_selected=i;return YES;}
    return Fail(error,[NSString stringWithFormat:@"Unknown technique: %@",name]);
}
- (NSArray<NSDictionary *> *)uniforms {
    std::lock_guard<std::mutex> lock(_lock);NSMutableArray *result=[NSMutableArray array];
    for(const auto &u:_program.module.uniforms) {
        NSString *label=S(Annotation(u.annotations,"ui_label"));
        NSMutableDictionary *entry=[@{@"name":S(u.name),@"type":S(u.type.description()),@"components":@(u.type.components()),
            @"values":UniformValues(u,_uniformData),@"defaultValues":UniformValues(u,_program.defaultUniformData),
            @"source":S(Annotation(u.annotations,"source")),@"uiLabel":label.length?label:S(u.name),
            @"uiTooltip":S(Annotation(u.annotations,"ui_tooltip")),@"uiType":S(Annotation(u.annotations,"ui_type")),
            @"uiItems":UIItems(u.annotations)} mutableCopy];
        for(const auto &names:{std::pair<const char *,NSString *>{"ui_min",@"uiMin"},{"ui_max",@"uiMax"},{"ui_step",@"uiStep"}}) {
            id value=NumericAnnotation(u.annotations,names.first);if(value)entry[names.second]=value;
        }
        [result addObject:[entry copy]];
    }return [result copy];
}
- (BOOL)setUniformNamed:(NSString *)name values:(NSArray<NSNumber *> *)values error:(NSError **)error {
    if(error)*error=nil;std::lock_guard<std::mutex> lock(_lock);
    for(const auto &u:_program.module.uniforms)if([S(u.name) isEqualToString:name]) {
        if(!Annotation(u.annotations,"source").empty())return Fail(error,@"Dynamic source uniforms cannot be edited manually.");
        if(values.count!=u.type.components())return Fail(error,@"Uniform component count does not match.");
        for(NSNumber *v in values)if(!std::isfinite(v.doubleValue))return Fail(error,@"Uniform values must be finite.");
        // Validate the entire vector before writing so a rejected update is atomic.
        for(NSNumber *number in values) {
            double v=number.doubleValue;
            if(u.type.is_floating_point()&&std::abs(v)>FLT_MAX)return Fail(error,@"Uniform exceeds float range.");
            if(!u.type.is_floating_point()&&!u.type.is_boolean()) {
                if(u.type.is_signed()&&(v<INT32_MIN||v>INT32_MAX))return Fail(error,@"Uniform exceeds integer range.");
                if(!u.type.is_signed()&&(v<0||v>UINT32_MAX))return Fail(error,@"Uniform exceeds unsigned integer range.");
            }
        }
        for(unsigned i=0;i<u.type.components();++i) {
            uint8_t *p=_uniformData.data()+u.offset+i*4;double v=values[i].doubleValue;
            if(u.type.is_floating_point()){if(std::abs(v)>FLT_MAX)return Fail(error,@"Uniform exceeds float range.");float x=(float)v;memcpy(p,&x,4);}
            else if(u.type.is_boolean()){uint32_t x=v!=0;memcpy(p,&x,4);}
            else if(u.type.is_signed()){if(v<INT32_MIN||v>INT32_MAX)return Fail(error,@"Uniform exceeds integer range.");int32_t x=(int32_t)v;memcpy(p,&x,4);}
            else {if(v<0||v>UINT32_MAX)return Fail(error,@"Uniform exceeds unsigned integer range.");uint32_t x=(uint32_t)v;memcpy(p,&x,4);}
        }return YES;
    }
    return Fail(error,[NSString stringWithFormat:@"Unknown uniform: %@",name]);
}

- (BOOL)shareResourcesWithEffect:(MSFXEffect *)effect error:(NSError **)error {
    if(error)*error=nil;
    if(!effect)return Fail(error,@"A compiled effect is required to share FX resources.");
    if(effect==self)return YES;
    std::scoped_lock lock(_lock,effect->_lock);
    if(_frame)return Fail(error,@"Share FX resources before this effect begins encoding.");
    if(_device!=effect->_device||_program.width!=effect->_program.width||_program.height!=effect->_program.height||
       ![_sourceConfiguration isEqual:effect->_sourceConfiguration])
        return Fail(error,@"Shared FX resources require the same source, Metal device, dimensions and compile options.");
    _resourceState=effect->_resourceState;
    _staticTextures=effect->_staticTextures;
    return YES;
}

- (id<MTLRenderPipelineState>)copyPipeline:(MTLPixelFormat)format error:(NSError **)error {
    @synchronized(_copyPipelines) {
        auto pipeline=_copyPipelines[@(format)];if(pipeline)return pipeline;
        auto *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[_copyLibrary newFunctionWithName:@"copyVS"];
        d.fragmentFunction=[_copyLibrary newFunctionWithName:@"copyPS"];d.colorAttachments[0].pixelFormat=format;
        pipeline=[_device newRenderPipelineStateWithDescriptor:d error:error];if(pipeline)_copyPipelines[@(format)]=pipeline;return pipeline;
    }
}
- (void)copyBuffer:(id<MTLCommandBuffer>)buffer source:(id<MTLTexture>)source destination:(id<MTLTexture>)destination pipeline:(id<MTLRenderPipelineState>)pipeline {
    auto *d=[MTLRenderPassDescriptor renderPassDescriptor];d.colorAttachments[0].texture=destination;
    d.colorAttachments[0].loadAction=MTLLoadActionDontCare;d.colorAttachments[0].storeAction=MTLStoreActionStore;
    auto encoder=[buffer renderCommandEncoderWithDescriptor:d];[encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];[encoder setCullMode:MTLCullModeNone];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];
}

- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)buffer texture:(id<MTLTexture>)target time:(double)seconds error:(NSError **)error {
    return [self encodeCommandBuffer:buffer texture:target depthTexture:nil time:seconds error:error];
}

- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)buffer texture:(id<MTLTexture>)target depthTexture:(id<MTLTexture>)depthTexture
                       time:(double)seconds error:(NSError **)error {
    if(error)*error=nil;
    if(!buffer||!target||buffer.device!=_device||target.device!=_device||buffer.status>=MTLCommandBufferStatusCommitted)return Fail(error,@"FX requires an uncommitted command buffer and texture on its Metal device.");
    if(target.width!=_program.width||target.height!=_program.height)return Fail(error,@"Frame size changed; reload the effect for the new dimensions.");
    if(target.framebufferOnly||target.sampleCount!=1||target.textureType!=MTLTextureType2D||target.mipmapLevelCount!=1||target.storageMode==MTLStorageModeMemoryless)return Fail(error,@"FX requires a readable, stored, single-sample 2D texture with one mip level.");
    MTLPixelFormat linear=Linear(target.pixelFormat);
    if(linear!=MTLPixelFormatBGRA8Unorm&&linear!=MTLPixelFormatRGBA8Unorm)return Fail(error,@"FX currently supports BGRA8/RGBA8 SDR targets, with or without sRGB.");
    if(target.usage!=MTLTextureUsageUnknown&&!(target.usage&MTLTextureUsageRenderTarget))return Fail(error,@"FX destination must support render-target usage.");
    if(!std::isfinite(seconds))seconds=0;
    NSUInteger selected;std::vector<uint8_t> uniformBytes;
    {
        std::lock_guard<std::mutex> lock(_lock);selected=_selected;uniformBytes=_uniformData;
        if(_techniqueRequiresDepth[selected]) {
            if(!depthTexture)return Fail(error,@"This technique requires a DEPTH input. Supply a readable R32Float depth texture from the current frame.");
            if(depthTexture.device!=_device)return Fail(error,@"The DEPTH texture must use the same Metal device as the effect.");
            if(depthTexture.framebufferOnly||depthTexture.sampleCount!=1||depthTexture.textureType!=MTLTextureType2D||
               depthTexture.storageMode==MTLStorageModeMemoryless||depthTexture.width==0||depthTexture.height==0)
                return Fail(error,@"DEPTH requires a readable, stored, single-sample 2D texture. Resolve and normalize the scene depth first.");
            if(depthTexture.pixelFormat!=MTLPixelFormatR32Float)
                return Fail(error,@"DEPTH input must be R32Float containing normalized 0...1 values; convert the scene depth format before encoding.");
            if(depthTexture.usage!=MTLTextureUsageUnknown&&!(depthTexture.usage&MTLTextureUsageShaderRead))
                return Fail(error,@"The DEPTH texture must permit Metal shader-read usage.");
        }
        for(const auto &u:_program.module.uniforms) {
            auto source=Annotation(u.annotations,"source");if(source.empty())continue;
            uint8_t *p=uniformBytes.data()+u.offset;
            unsigned components=u.type.components();
            if(source=="timer") {
                double v=seconds*1000.0;
                if(u.type.is_floating_point()){float x=(float)v;memcpy(p,&x,4);}
                else{uint32_t x=(uint32_t)std::clamp(v,0.0,(double)UINT32_MAX);memcpy(p,&x,4);}
            } else if(source=="frametime") {
                double v=(_frame==0?0.0:std::max(0.0,seconds-_previousTime)*1000.0);
                if(u.type.is_floating_point()){float x=(float)v;memcpy(p,&x,4);}
                else{uint32_t x=(uint32_t)std::clamp(v,0.0,(double)UINT32_MAX);memcpy(p,&x,4);}
            } else if(source=="framecount") {
                double v=(double)_frame;
                if(u.type.is_floating_point()){float x=(float)v;memcpy(p,&x,4);}
                else{uint32_t x=(uint32_t)(_frame&0xFFFFFFFF);memcpy(p,&x,4);}
            } else if(source=="pingpong") {
                id minObj=NumericAnnotation(u.annotations,"min");
                id maxObj=NumericAnnotation(u.annotations,"max");
                id stepObj=NumericAnnotation(u.annotations,"step");
                double minVal=[minObj respondsToSelector:@selector(doubleValue)]?[minObj doubleValue]:0.0;
                double maxVal=[maxObj respondsToSelector:@selector(doubleValue)]?[maxObj doubleValue]:1.0;
                double stepVal=[stepObj respondsToSelector:@selector(doubleValue)]?[stepObj doubleValue]:1.0;
                if([stepObj isKindOfClass:NSArray.class]&&[(NSArray *)stepObj count]>0)stepVal=[[(NSArray *)stepObj firstObject] doubleValue];
                double range=maxVal-minVal;if(range<=0.0)range=1.0;if(stepVal<=0.0)stepVal=1.0;
                double cycle=fmod(seconds*stepVal,2.0*range);if(cycle<0.0)cycle+=2.0*range;
                double curVal=(cycle<=range)?(minVal+cycle):(maxVal-(cycle-range));
                double dir=(cycle<=range)?1.0:-1.0;
                if(u.type.is_floating_point()){
                    float x=(float)curVal;memcpy(p,&x,4);
                    if(components>1){float y=(float)dir;memcpy(p+4,&y,4);}
                    for(unsigned c=2;c<components;++c){float zero=0;memcpy(p+c*4,&zero,4);}
                } else {
                    int32_t x=(int32_t)curVal;memcpy(p,&x,4);
                    if(components>1){int32_t y=(int32_t)dir;memcpy(p+4,&y,4);}
                    for(unsigned c=2;c<components;++c){int32_t zero=0;memcpy(p+c*4,&zero,4);}
                }
            } else if(source=="random") {
                id minObj=NumericAnnotation(u.annotations,"min");
                id maxObj=NumericAnnotation(u.annotations,"max");
                double minVal=[minObj respondsToSelector:@selector(doubleValue)]?[minObj doubleValue]:0.0;
                double maxVal=[maxObj respondsToSelector:@selector(doubleValue)]?[maxObj doubleValue]:1000.0;
                for(unsigned c=0;c<components;++c) {
                    double r=(double)arc4random()/(double)UINT32_MAX;
                    double val=minVal+r*(maxVal-minVal);
                    if(u.type.is_floating_point()){float x=(float)val;memcpy(p+c*4,&x,4);}
                    else if(u.type.is_signed()){int32_t x=(int32_t)val;memcpy(p+c*4,&x,4);}
                    else{uint32_t x=(uint32_t)std::clamp(val,0.0,(double)UINT32_MAX);memcpy(p+c*4,&x,4);}
                }
            } else if(source=="bufready_depth"||source=="bufready_wdepth") {
                uint32_t val=(depthTexture!=nil)?1:0;
                if(u.type.is_floating_point()){float x=(float)val;memcpy(p,&x,4);}
                else{memcpy(p,&val,4);}
            } else if(source=="depth_render_size"||source=="depth_resolution"||source=="depth_viewport_size") {
                double w=depthTexture?(double)depthTexture.width:(double)target.width;
                double h=depthTexture?(double)depthTexture.height:(double)target.height;
                if(u.type.is_floating_point()){float fw=(float)w,fh=(float)h;memcpy(p,&fw,4);if(components>1)memcpy(p+4,&fh,4);}
                else{uint32_t iw=(uint32_t)w,ih=(uint32_t)h;memcpy(p,&iw,4);if(components>1)memcpy(p+4,&ih,4);}
            } else if(source=="mousepoint") {
                float mx=(float)(target.width/2.0),my=(float)(target.height/2.0);
                if(u.type.is_floating_point()){memcpy(p,&mx,4);if(components>1)memcpy(p+4,&my,4);}
            }
        }
        ++_frame;_previousTime=seconds;
    }
    auto initialPipeline=[self copyPipeline:MTLPixelFormatRGBA8Unorm error:error];
    auto finalPipeline=[self copyPipeline:target.pixelFormat error:error];if(!initialPipeline||!finalPipeline)return NO;
    NSMutableArray *held=[NSMutableArray arrayWithObjects:self,target,initialPipeline,finalPipeline,nil];
    if(depthTexture)[held addObject:depthTexture];
    id<MTLTexture> backA=MSAcquireScratchTexture(_device,MTLPixelFormatRGBA8Unorm,target.width,target.height,1);
    id<MTLTexture> backB=MSAcquireScratchTexture(_device,MTLPixelFormatRGBA8Unorm,target.width,target.height,1);
    id<MTLTexture> input=MSAcquireScratchTexture(_device,target.pixelFormat,target.width,target.height,1);
    if(!backA||!backB||!input)return Fail(error,@"Could not allocate FX color buffers.");
    MSRecycleScratchTexture(backA, buffer);
    MSRecycleScratchTexture(backB, buffer);
    MSRecycleScratchTexture(input, buffer);
    [held addObjectsFromArray:@[backA,backB,input]];
    auto inputView=[input newTextureViewWithPixelFormat:linear];if(!inputView)return Fail(error,@"Could not create the FX color view.");[held addObject:inputView];
    // Each recording buffer has a writable texture set. Techniques from one FX
    // file share that set, while other in-flight frames only read immutable,
    // completed history. This also works when buffers use different queues or
    // are committed in a different order from CPU encoding.
    std::shared_ptr<FXResourceState> resources;
    {std::lock_guard<std::mutex> lock(_lock);resources=_resourceState;}
    MSFXFrameResources *frameResources;
    {
        std::lock_guard<std::mutex> lock(resources->lock);
        frameResources=[resources->frames objectForKey:buffer];
        if(!frameResources) {
            frameResources=[MSFXFrameResources new];
            frameResources.textures=[NSMutableDictionary dictionary];
            frameResources.previous=resources->history;
            frameResources.sequence=++resources->nextSequence;
            for(const auto &t:_program.module.textures)if(t.semantic.empty()) {
                NSString *key=S(t.unique_name);
                if(_staticTextures[key])frameResources.textures[key]=_staticTextures[key];
                else {
                    auto image=NewTexture(_device,Format(t.format),t.width,t.height,t.levels);
                    if(!image)return Fail(error,[NSString stringWithFormat:@"Could not allocate texture %@.",S(t.name)]);
                    frameResources.textures[key]=image;
                }
            }
            [resources->frames setObject:frameResources forKey:buffer];
            NSMutableDictionary *history=[NSMutableDictionary dictionary];
            for(const auto &name:_persistentTextureNames) {
                NSString *key=S(name);if(frameResources.textures[key])history[key]=frameResources.textures[key];
            }
            NSDictionary *completedTextures=[history copy];
            const uint64_t sequence=frameResources.sequence;
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed){
                if(completed.status!=MTLCommandBufferStatusCompleted)return;
                std::lock_guard<std::mutex> guard(resources->lock);
                if(sequence>resources->completedSequence){resources->history=completedTextures;resources->completedSequence=sequence;}
            }];
        }
    }
    NSMutableDictionary<NSString *,id<MTLTexture>> *textures=frameResources.textures;
    [held addObject:frameResources];
    [held addObjectsFromArray:textures.allValues];
    [held addObjectsFromArray:frameResources.previous.allValues];
    id<MTLBuffer> constants=nil;
    const bool inlineUniforms = (!uniformBytes.empty() && uniformBytes.size() <= 4096);
    if(!uniformBytes.empty() && !inlineUniforms) {
        constants=[_device newBufferWithBytes:uniformBytes.data() length:uniformBytes.size() options:MTLResourceStorageModeShared];
        if(!constants)return Fail(error,@"Could not allocate FX uniforms.");
        [held addObject:constants];
    }
    // Capture the container before adding per-pass views; the command buffer owns
    // this container through completion even when retainedReferences is disabled.
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed){(void)completed;(void)held.count;}];
    Blit(buffer,target,input);
    [self copyBuffer:buffer source:inputView destination:backA pipeline:initialPipeline];
    if(!frameResources.initialized) {
        for(const auto &t:_program.module.textures)if(t.semantic.empty()&&!_staticTextures[S(t.unique_name)]) {
            NSString *key=S(t.unique_name);
            if(frameResources.previous[key])Blit(buffer,frameResources.previous[key],textures[key]);
            else Clear(buffer,textures[key]);
        }
        frameResources.initialized=YES;
    }
    const auto &technique=_program.module.techniques[selected];
    for(size_t index=0;index<technique.passes.size();++index) {
        const auto &pass=technique.passes[index];bool implicit=pass.render_target_names[0].empty();
        if(implicit && (pass.blend_enable[0] || !pass.clear_render_targets)) Blit(buffer,backA,backB);
        NSMutableArray<id<MTLTexture>> *outputs=[NSMutableArray array];
        auto *descriptor=[MTLRenderPassDescriptor renderPassDescriptor];
        for(unsigned i=0;i<8;++i) {
            id<MTLTexture> output=nil;
            if(implicit&&i==0)output=backB;
            else if(!pass.render_target_names[i].empty())output=textures[S(pass.render_target_names[i])];
            if(!output)continue;
            [outputs addObject:output];
            if(pass.srgb_write_enable){output=[output newTextureViewWithPixelFormat:SRGB(output.pixelFormat)];if(!output)return Fail(error,@"Could not create sRGB render-target view.");[held addObject:output];}
            auto a=descriptor.colorAttachments[i];a.texture=output;
            a.loadAction=pass.clear_render_targets?MTLLoadActionClear:MTLLoadActionLoad;a.storeAction=MTLStoreActionStore;
        }
        // Snapshot explicit read/write aliases before creating the render encoder.
        NSMutableDictionary<NSString *,id<MTLTexture>> *reads=[textures mutableCopy];
        for(const std::string &entryName:{pass.vs_entry_point,pass.ps_entry_point}) {
            const auto &entry=_program.entryPoints.at(entryName);
            for(const auto &binding:entry.sampledBindings) {
                const auto &t=_program.module.textures[binding.textureIndex];
                if(!t.semantic.empty())continue;
                auto image=reads[S(t.unique_name)];
                if([outputs indexOfObjectIdenticalTo:image]!=NSNotFound) {
                    auto snapshot=MSAcquireScratchTexture(_device,image.pixelFormat,image.width,image.height,image.mipmapLevelCount);
                    if(!snapshot)return Fail(error,@"Could not snapshot a pass read/write alias.");
                    MSRecycleScratchTexture(snapshot, buffer);
                    [held addObject:snapshot];Blit(buffer,image,snapshot);reads[S(t.unique_name)]=snapshot;
                }
            }
        }
        auto encoder=[buffer renderCommandEncoderWithDescriptor:descriptor];if(!encoder)return Fail(error,@"Could not create an FX pass encoder.");
        encoder.label=S(technique.name+" / "+pass.name);[encoder setRenderPipelineState:_pipelines[selected][index]];
        [encoder setCullMode:MTLCullModeNone];
        auto first=outputs.firstObject;
        [encoder setViewport:MTLViewport{0,0,double(pass.viewport_width?:first.width),double(pass.viewport_height?:first.height),0,1}];
        for(const std::string &entryName:{pass.vs_entry_point,pass.ps_entry_point}) {
            const auto &entry=_program.entryPoints.at(entryName);bool vertex=entry.stage==shader_type::vertex;
            if(entry.uniformBufferSlot>=0&&!uniformBytes.empty()) {
                if(inlineUniforms) {
                    if(vertex)[encoder setVertexBytes:uniformBytes.data() length:uniformBytes.size() atIndex:entry.uniformBufferSlot];
                    else [encoder setFragmentBytes:uniformBytes.data() length:uniformBytes.size() atIndex:entry.uniformBufferSlot];
                } else if(constants) {
                    if(vertex)[encoder setVertexBuffer:constants offset:0 atIndex:entry.uniformBufferSlot];
                    else [encoder setFragmentBuffer:constants offset:0 atIndex:entry.uniformBufferSlot];
                }
            }
            for(const auto &binding:entry.sampledBindings) {
                const auto &t=_program.module.textures[binding.textureIndex];const auto &sampler=_program.module.samplers[binding.samplerIndex];
                id<MTLTexture> image=t.semantic.empty()?reads[S(t.unique_name)]:(IsDepth(t)?depthTexture:backA);
                if(sampler.srgb&&SRGB(image.pixelFormat)!=image.pixelFormat) {image=[image newTextureViewWithPixelFormat:SRGB(image.pixelFormat)];if(image)[held addObject:image];}
                if(!image){[encoder endEncoding];return Fail(error,@"FX texture binding is unavailable.");}
                if(vertex){[encoder setVertexTexture:image atIndex:binding.textureSlot];[encoder setVertexSamplerState:_samplers[binding.samplerIndex] atIndex:binding.samplerSlot];}
                else {[encoder setFragmentTexture:image atIndex:binding.textureSlot];[encoder setFragmentSamplerState:_samplers[binding.samplerIndex] atIndex:binding.samplerSlot];}
            }
        }
        [encoder drawPrimitives:Primitive(pass.topology) vertexStart:0 vertexCount:pass.num_vertices];[encoder endEncoding];
        if(pass.generate_mipmaps)for(id<MTLTexture> output in outputs)if(output.mipmapLevelCount>1){auto blit=[buffer blitCommandEncoder];[blit generateMipmapsForTexture:output];[blit endEncoding];}
        if(implicit)std::swap(backA,backB);
    }
    id<MTLTexture> final=backA;
    if(target.pixelFormat!=linear){final=[backA newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];if(!final)return Fail(error,@"Could not create output color view.");[held addObject:final];}
    [self copyBuffer:buffer source:final destination:target pipeline:finalPipeline];return YES;
}
@end
