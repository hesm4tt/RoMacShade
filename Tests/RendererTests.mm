#import "MacShade.h"
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <memory>

static int checks = 0;
static void check(bool condition, const char *message) {
    ++checks;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width=64, NSUInteger height=40) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:d];
}
static std::vector<uint8_t> pixels(NSUInteger w, NSUInteger h) {
    std::vector<uint8_t> result(w*h*4);
    for (NSUInteger y=0; y<h; ++y) for (NSUInteger x=0; x<w; ++x) {
        size_t i = (y*w+x)*4;
        result[i] = 15+(x*137/w); result[i+1] = 23+(y*109/h);
        result[i+2] = 31+((x+y)*83/(w+h)); result[i+3] = 40+(x*175/w);
    }
    return result;
}
static bool render(MSRenderer *renderer, id<MTLCommandQueue> queue, id<MTLTexture> target, MSSettings settings, bool unretained=false) {
    id<MTLCommandBuffer> buffer = unretained ? [queue commandBufferWithUnretainedReferences] : [queue commandBuffer];
    NSError *error = nil;
    if (![renderer encodeCommandBuffer:buffer texture:target settings:settings error:&error]) {
        fprintf(stderr, "Encode error: %s\n", error.localizedDescription.UTF8String); return false;
    }
    [buffer commit]; [buffer waitUntilCompleted];
    if (buffer.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "GPU error: %s\n", buffer.error.localizedDescription.UTF8String); return false;
    }
    return true;
}
static int maxDifference(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    int maximum=0;
    for (size_t i=0; i<a.size(); ++i) maximum=std::max(maximum, std::abs(int(a[i])-int(b[i])));
    return maximum;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    check(device != nil, "Metal device available");
    NSError *error=nil;
    MSRenderer *renderer=[[MSRenderer alloc] initWithDevice:device error:&error];
    if (error) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    check(renderer != nil, "Metal shader compiles");
    id<MTLCommandQueue> queue=[device newCommandQueue];
    for (MTLPixelFormat format : { MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB }) {
        id<MTLTexture> target=texture(device, format);
        auto input=pixels(target.width,target.height), output=input;
        [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0 withBytes:input.data() bytesPerRow:target.width*4];
        check(render(renderer,queue,target,MSNeutralSettings()), "neutral render completes");
        [target getBytes:output.data() bytesPerRow:target.width*4 fromRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0];
        check(maxDifference(input,output)<=2, "neutral preserves color, alpha and pixel orientation (8-bit/sRGB)");
    }
    {
        id<MTLTexture> target=texture(device,MTLPixelFormatRGBA16Float,17,11);
        std::vector<_Float16> input(17*11*4), output(input.size());
        for (size_t i=0; i<input.size(); ++i) input[i]=_Float16(float((i*17)%89)/100.0f);
        [target replaceRegion:MTLRegionMake2D(0,0,17,11) mipmapLevel:0 withBytes:input.data() bytesPerRow:17*8];
        check(render(renderer,queue,target,MSNeutralSettings()), "float render completes");
        [target getBytes:output.data() bytesPerRow:17*8 fromRegion:MTLRegionMake2D(0,0,17,11) mipmapLevel:0];
        float delta=0; for (size_t i=0; i<input.size(); ++i) delta=std::max(delta,std::abs(float(input[i])-float(output[i])));
        check(delta<0.002f,"float neutral preserves image");
    }
    {
        id<MTLTexture> target=texture(device,MTLPixelFormatRGBA8Unorm,8,8);
        std::vector<uint8_t> input(8*8*4), output(input.size());
        for(size_t i=0;i<input.size();i+=4) { input[i]=26;input[i+1]=51;input[i+2]=77;input[i+3]=137; }
        [target replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:input.data() bytesPerRow:8*4];
        MSSettings s=MSNeutralSettings(); s.exposure=1;
        check(render(renderer,queue,target,s),"exposure render completes");
        [target getBytes:output.data() bytesPerRow:8*4 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        check(std::abs(int(output[0])-52)<=2 && std::abs(int(output[1])-102)<=2 && std::abs(int(output[2])-154)<=2 && output[3]==137,"one exposure stop doubles linear RGB and preserves alpha");
        [target replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:input.data() bytesPerRow:8*4];
        s=MSNeutralSettings(); s.saturation=0;
        check(render(renderer,queue,target,s),"desaturation render completes");
        [target getBytes:output.data() bytesPerRow:8*4 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        check(output[0]==output[1] && output[1]==output[2] && output[3]==137,"zero saturation produces grayscale and preserves alpha");
    }
    {
        id<MTLTexture> target=texture(device,MTLPixelFormatRGBA8Unorm,33,33);
        std::vector<uint8_t> input(33*33*4,0), output(input.size());
        for (size_t i=3;i<input.size();i+=4) input[i]=255;
        size_t center=(16*33+16)*4;
        input[center]=input[center+1]=input[center+2]=255;
        [target replaceRegion:MTLRegionMake2D(0,0,33,33) mipmapLevel:0 withBytes:input.data() bytesPerRow:33*4];
        MSSettings s=MSNeutralSettings(); s.bloom=1;
        check(render(renderer,queue,target,s),"bloom render completes");
        [target getBytes:output.data() bytesPerRow:33*4 fromRegion:MTLRegionMake2D(0,0,33,33) mipmapLevel:0];
        check(output[(16*33+19)*4]>0 && output[0]==0,"bloom spills into a neighboring dark pixel without globally lifting black");
        for (size_t i=0;i<input.size();i+=4) input[i]=input[i+1]=input[i+2]=128;
        [target replaceRegion:MTLRegionMake2D(0,0,33,33) mipmapLevel:0 withBytes:input.data() bytesPerRow:33*4];
        s=MSNeutralSettings(); s.vignette=1;
        check(render(renderer,queue,target,s),"vignette render completes");
        [target getBytes:output.data() bytesPerRow:33*4 fromRegion:MTLRegionMake2D(0,0,33,33) mipmapLevel:0];
        check(output[0]<output[center] && std::abs(int(output[center])-128)<=1,"vignette darkens corners while preserving the center");
    }
    {
        id<MTLTexture> target=texture(device,MTLPixelFormatRGBA16Float,1,1);
        _Float16 input[4]={0.2,0.3,0.4,0.6}, output[4];
        [target replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:input bytesPerRow:8];
        MSSettings s={NAN,INFINITY,-INFINITY,NAN,INFINITY,NAN,INFINITY,NAN,INFINITY,NAN};
        check(render(renderer,queue,target,s),"nonfinite settings and 1x1 image render safely");
        [target getBytes:output bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        check(std::isfinite(float(output[0])) && std::isfinite(float(output[1])) && std::isfinite(float(output[2])),"nonfinite settings do not reach output");
    }
    {
        id<MTLTexture> target=texture(device,MTLPixelFormatRGBA8Unorm);
        id<MTLCommandBuffer> buffer=[queue commandBuffer];
        [buffer commit]; [buffer waitUntilCompleted];
        error=nil;
        check(![renderer encodeCommandBuffer:buffer texture:target settings:MSDefaultSettings() error:&error] && error!=nil,"committed command buffer is rejected");
        id<MTLTexture> unsupported=texture(device,MTLPixelFormatR8Unorm);
        error=nil;
        check(![renderer encodeCommandBuffer:[queue commandBuffer] texture:unsupported settings:MSDefaultSettings() error:&error] && error!=nil,"unsupported format is rejected");
        buffer=[queue commandBuffer]; [buffer enqueue];
        auto input=pixels(target.width,target.height);
        [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0 withBytes:input.data() bytesPerRow:target.width*4];
        check([renderer encodeCommandBuffer:buffer texture:target settings:MSDefaultSettings() error:&error],"enqueued but uncommitted buffer can encode");
        [buffer commit];[buffer waitUntilCompleted];
        check(buffer.status==MTLCommandBufferStatusCompleted,"enqueued buffer completes");
    }
    {
        // Shared renderer, independent queues, separate images, and unretained
        // command buffers stress pipeline synchronization and resource keepalive.
        auto passed=std::make_shared<std::atomic<bool>>(true);
        dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^(size_t index) { @autoreleasepool {
            id<MTLCommandQueue> localQueue=[device newCommandQueue];
            id<MTLTexture> target=texture(device, index%2 ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm,31+index,19+index);
            auto input=pixels(target.width,target.height), output=input;
            [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0 withBytes:input.data() bytesPerRow:target.width*4];
            if (!render(renderer,localQueue,target,MSNeutralSettings(),true)) { passed->store(false); return; }
            [target getBytes:output.data() bytesPerRow:target.width*4 fromRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0];
            if (maxDifference(input,output)>2) passed->store(false);
        }});
        check(passed->load(),"concurrent queues, changing sizes and unretained buffers preserve pixels");
    }
    printf("PASS: %d GPU checks on %s\n", checks, device.name.UTF8String);
    return 0;
}}
