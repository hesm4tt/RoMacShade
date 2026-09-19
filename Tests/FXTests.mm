#import "FXRuntime.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

static const NSUInteger width = 32, height = 20;
static int checks = 0;

static void check(bool condition, const char *message) {
    ++checks;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static id<MTLTexture> makeTexture(id<MTLDevice> device, NSUInteger w = width, NSUInteger h = height, MTLPixelFormat format = MTLPixelFormatRGBA8Unorm) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                       width:w height:h mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:descriptor];
}

static std::vector<uint8_t> gradient(void) {
    std::vector<uint8_t> bytes(width * height * 4);
    for (NSUInteger y = 0; y < height; ++y) for (NSUInteger x = 0; x < width; ++x) {
        size_t i = (y * width + x) * 4;
        // Asymmetry detects horizontal/vertical flips; low RGB avoids clipping.
        bytes[i] = uint8_t(9 + x * 79 / width);
        bytes[i + 1] = uint8_t(19 + y * 83 / height);
        bytes[i + 2] = uint8_t(7 + (3*x + y) * 71 / (3*width + height));
        bytes[i + 3] = uint8_t(37 + (x + 2*y) * 179 / (width + 2*height));
    }
    return bytes;
}

static void upload(id<MTLTexture> texture, const std::vector<uint8_t> &bytes) {
    [texture replaceRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0
                withBytes:bytes.data() bytesPerRow:texture.width * 4];
}

static std::vector<uint8_t> download(id<MTLTexture> texture) {
    std::vector<uint8_t> bytes(texture.width * texture.height * 4);
    [texture getBytes:bytes.data() bytesPerRow:texture.width * 4
          fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
    return bytes;
}

static int difference(const std::vector<uint8_t> &actual, const std::vector<uint8_t> &expected) {
    if (actual.size() != expected.size()) return 256;
    int delta = 0;
    for (size_t i = 0; i < actual.size(); ++i)
        delta = std::max(delta, std::abs(int(actual[i]) - int(expected[i])));
    return delta;
}

static std::vector<uint8_t> exposed(std::vector<uint8_t> input, double stops) {
    for (size_t i = 0; i < input.size(); ++i) if (i % 4 != 3)
        input[i] = uint8_t(std::clamp(std::lround(double(input[i]) * std::exp2(stops)), 0L, 255L));
    return input;
}

static std::vector<uint8_t> vibranced(std::vector<uint8_t> input, double strength=0.15) {
    for(size_t i=0;i<input.size();i+=4) {
        double r=input[i]/255.0,g=input[i+1]/255.0,b=input[i+2]/255.0;
        double luma=.212656*r+.715158*g+.072186*b;
        double factor=1.0+strength*(1.0-(std::max({r,g,b})-std::min({r,g,b})));
        for(size_t j=0;j<3;++j)input[i+j]=(uint8_t)std::clamp(std::lround((luma+(input[i+j]/255.0-luma)*factor)*255),0L,255L);
    }
    return input;
}

static bool render(MSFXEffect *effect, id<MTLCommandQueue> queue, id<MTLTexture> target, bool unretained = false) {
    id<MTLCommandBuffer> buffer = unretained ? [queue commandBufferWithUnretainedReferences] : [queue commandBuffer];
    NSError *error = nil;
    if (![effect encodeCommandBuffer:buffer texture:target time:1.25 error:&error]) {
        fprintf(stderr, "FX encode error: %s\n", error.localizedDescription.UTF8String);
        return false;
    }
    [buffer commit];
    [buffer waitUntilCompleted];
    if (buffer.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FX GPU error: %s\n", buffer.error.localizedDescription.UTF8String);
        return false;
    }
    return true;
}

static MSFXEffect *load(NSURL *root, NSString *path, id<MTLDevice> device, NSError **error) {
    return [[MSFXEffect alloc] initWithURL:[root URLByAppendingPathComponent:path]
                                  device:device width:width height:height error:error];
}

static NSDictionary *uniform(MSFXEffect *effect, NSString *name) {
    for (NSDictionary *entry in effect.uniforms) if ([entry[@"name"] isEqual:name]) return entry;
    return nil;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSURL *root;
    if (argc > 1) root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
    else root = NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    check(device != nil, "Metal device available");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    check(queue != nil, "Metal command queue available");
    NSError *error = nil;
    MSFXEffect *effect = load(root, @"Effects/ColorGrade.fx", device, &error);
    if (!effect) fprintf(stderr, "FX compile error: %s\n", error.localizedDescription.UTF8String);
    check(effect != nil, "ColorGrade.fx and included fullscreen shader compile");
    check([effect.techniqueNames containsObject:@"ColorGrade"] && [effect.techniqueNames containsObject:@"Copy"],
          "technique names are reflected");
    check([effect.activeTechnique isEqualToString:@"ColorGrade"], "first technique is selected by default");
    NSDictionary *exposure = uniform(effect, @"Exposure"), *saturation = uniform(effect, @"Saturation");
    check(exposure != nil && saturation != nil, "adjustable uniform names are reflected");
    check([exposure[@"components"] unsignedIntegerValue] == 1 && [exposure[@"values"] count] == 1,
          "exposure reports one scalar component");
    check(std::abs([exposure[@"values"][0] doubleValue] - 0.5) < 1e-6 &&
          std::abs([saturation[@"values"][0] doubleValue] - 1.0) < 1e-6, "source uniform defaults are preserved");
    check([exposure[@"uiLabel"] isEqualToString:@"Exposure (stops)"]&&[exposure[@"uiType"] isEqualToString:@"slider"]&&
          [exposure[@"uiMin"] doubleValue]==-2&&[exposure[@"uiMax"] doubleValue]==2,
          "source slider annotations are reflected for UI controls");
    check([exposure[@"defaultValues"] isEqual:@[@0.5]]&&[saturation[@"uiLabel"] isEqualToString:@"Saturation"],
          "uniform reflection includes fixed defaults and a label fallback");

    auto input = gradient();
    id<MTLTexture> target = makeTexture(device);
    check(target != nil, "test render target allocated");
    upload(target, input);
    check(render(effect, queue, target), "default uniform render completes");
    check(difference(download(target), exposed(input, 0.5)) <= 2, "default half-stop exposure preserves alpha and orientation");

    error = nil;
    check([effect setUniformNamed:@"Exposure" values:@[@1.0] error:&error], "exposure uniform accepts a new scalar");
    check([uniform(effect,@"Exposure")[@"defaultValues"] isEqual:@[@0.5]],"editing a uniform leaves its reflected default intact");
    upload(target, input);
    check(render(effect, queue, target), "one-stop exposure render completes");
    check(difference(download(target), exposed(input, 1.0)) <= 2, "one stop doubles linear RGB without changing alpha");

    error = nil;
    check([effect setUniformNamed:@"Exposure" values:@[@0.0] error:&error], "exposure resets to identity");
    upload(target, input);
    check(render(effect, queue, target, true), "identity render completes with unretained command-buffer resources");
    check(difference(download(target), input) <= 1, "zero exposure preserves every asymmetric pixel and alpha");

    error = nil;
    check(![effect setUniformNamed:@"NotAUniform" values:@[@0.0] error:&error] && error.localizedDescription.length > 0,
          "unknown uniform is rejected with a diagnostic");
    error = nil;
    check(![effect setUniformNamed:@"Exposure" values:@[@0.0, @1.0] error:&error] && error.localizedDescription.length > 0,
          "wrong uniform component count is rejected");
    error = nil;
    check(![effect setUniformNamed:@"Exposure" values:@[@(NAN)] error:&error] && error.localizedDescription.length > 0,
          "nonfinite uniform value is rejected");
    error = nil;
    check(![effect selectTechniqueNamed:@"NotATechnique" error:&error] && error.localizedDescription.length > 0,
          "unknown technique is rejected with a diagnostic");
    check([effect.activeTechnique isEqualToString:@"ColorGrade"], "failed technique selection preserves active technique");
    upload(target, input);
    check(render(effect, queue, target) && difference(download(target), input) <= 1,
          "rejected uniform updates leave prior values intact");

    error = nil;
    check([effect setUniformNamed:@"Exposure" values:@[@1.0] error:&error], "restore nonneutral exposure before selecting Copy");
    check([effect selectTechniqueNamed:@"Copy" error:&error], "alternate technique is selectable");
    upload(target, input);
    check(render(effect, queue, target) && difference(download(target), input) <= 1,
          "selected Copy technique bypasses grading and preserves orientation");
    check([effect selectTechniqueNamed:@"ColorGrade" error:&error], "original technique remains selectable");

    for (MTLPixelFormat format : {MTLPixelFormatRGBA8Unorm_sRGB, MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB}) {
        auto colorTarget=makeTexture(device,width,height,format);
        upload(colorTarget,input);
        check(render(effect,queue,colorTarget) && difference(download(colorTarget),exposed(input,1.0))<=2,
              "FX operates on encoded SDR values consistently across RGBA/BGRA and sRGB drawable formats");
    }
    MSFXEffect *srgb=load(root,@"Tests/Fixtures/SRGBRoundtrip.fx",device,&error);
    if(!srgb)fprintf(stderr,"sRGB compile error: %s\n",error.localizedDescription.UTF8String);
    check(srgb!=nil,"sRGB sampler/write effect compiles");
    upload(target,input);
    check(render(srgb,queue,target)&&difference(download(target),input)<=2,"sRGB sampler decode and render-target encode preserve pixels");

    MSFXEffect *vibrance=load(root,@"Effects/SweetFX/Vibrance.fx",device,&error);
    if(!vibrance)fprintf(stderr,"SweetFX compile error: %s\n",error.localizedDescription.UTF8String);
    check(vibrance!=nil,"unmodified upstream SweetFX Vibrance compiles with standard include files");
    auto opaque=input;for(size_t i=3;i<opaque.size();i+=4)opaque[i]=255;
    upload(target,opaque);
    auto expected=opaque;
    for(size_t i=0;i<opaque.size();i+=4) {
        double r=opaque[i]/255.0,g=opaque[i+1]/255.0,b=opaque[i+2]/255.0;
        double luma=.212656*r+.715158*g+.072186*b;
        double factor=1.0+.15*(1.0-(std::max({r,g,b})-std::min({r,g,b})));
        for(size_t j=0;j<3;++j)expected[i+j]=(uint8_t)std::clamp(std::lround((luma+(opaque[i+j]/255.0-luma)*factor)*255),0L,255L);
    }
    bool vibranceRendered=render(vibrance,queue,target);
    auto vibranceActual=download(target);
    if(difference(vibranceActual,expected)>2) {
        fprintf(stderr,"Vibrance delta=%d; pixel actual=(%u,%u,%u,%u) expected=(%u,%u,%u,%u); uniforms=%s\n",difference(vibranceActual,expected),
            vibranceActual[0],vibranceActual[1],vibranceActual[2],vibranceActual[3],expected[0],expected[1],expected[2],expected[3],vibrance.uniforms.description.UTF8String);
    }
    check(vibranceRendered&&difference(vibranceActual,expected)<=2,"upstream Vibrance matches CPU reference RGB and preserves unwritten alpha");
    error=nil;
    check(![vibrance setUniformNamed:@"VibranceRGBBalance" values:@[@0.5,@1e100,@1] error:&error],"out-of-range vector update is rejected");
    check([uniform(vibrance,@"VibranceRGBBalance")[@"values"] isEqual:@[@1,@1,@1]],"failed vector update is atomic");

    // Compile options must affect real source and resolve a separate include directory.
    NSURL *temporary=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"macshade-fx-options-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSURL *includeDirectory=[temporary URLByAppendingPathComponent:@"includes" isDirectory:YES];
    check([NSFileManager.defaultManager createDirectoryAtURL:includeDirectory withIntermediateDirectories:YES attributes:nil error:&error],
          "temporary compiler-options fixture directory is created");
    NSString *includeSource=@"#ifndef TEST_GAIN\n#error TEST_GAIN must be supplied\n#endif\n"
        "uniform float Gain < ui_label=\"Preset gain\"; ui_tooltip=\"Defined at compile time\"; ui_type=\"slider\"; ui_min=0.0; ui_max=2.0; ui_step=0.125; > = TEST_GAIN;\n"
        "uniform int Choice < ui_type=\"combo\"; ui_items=\"First\\0Second\\0\"; > = 1;\n";
    check([includeSource writeToURL:[includeDirectory URLByAppendingPathComponent:@"Options.fxh"] atomically:YES encoding:NSUTF8StringEncoding error:&error],
          "external include fixture is written");
    NSString *effectSource=@"#include \"Options.fxh\"\n"
        "texture2D Scene : COLOR; sampler2D Sampler { Texture=Scene; };\n"
        "void VS(uint id:SV_VertexID,out float4 p:SV_Position,out float2 uv:TEXCOORD0){uv=float2((id<<1)&2,id&2);p=float4(uv*float2(2,-2)+float2(-1,1),0,1);}\n"
        "float4 PS(float4 p:SV_Position,float2 uv:TEXCOORD0):SV_Target{float4 c=tex2D(Sampler,uv);return float4(c.rgb*Gain,c.a);}\n"
        "technique Defined { pass { VertexShader=VS;PixelShader=PS; } }\n";
    NSURL *optionsFile=[temporary URLByAppendingPathComponent:@"Options.fx"];
    check([effectSource writeToURL:optionsFile atomically:YES encoding:NSUTF8StringEncoding error:&error],"compiler-options effect fixture is written");
    MSFXEffect *defined=[[MSFXEffect alloc] initWithURL:optionsFile device:device width:width height:height
        definitions:@{@"TEST_GAIN":@"0.5"} includeDirectories:@[includeDirectory] error:&error];
    if(!defined)fprintf(stderr,"Options compile error: %s\n",error.localizedDescription.UTF8String);
    check(defined!=nil,"supplied macro definitions and include directories compile an effect");
    NSDictionary *gain=uniform(defined,@"Gain"),*choice=uniform(defined,@"Choice");
    check([gain[@"defaultValues"] isEqual:@[@0.5]]&&[gain[@"uiStep"] doubleValue]==.125&&
          [gain[@"uiTooltip"] isEqualToString:@"Defined at compile time"],"macro default and tooltip/step annotations are preserved");
    check([choice[@"uiItems"] isEqual:@[@"First",@"Second"]]&&[choice[@"uiType"] isEqualToString:@"combo"],
          "NUL-separated combo choices are reflected without a trailing empty item");
    upload(target,input);
    check(render(defined,queue,target)&&difference(download(target),exposed(input,-1))<=1,
          "compile-time definition changes GPU output as requested");
    error=nil;
    check(![[MSFXEffect alloc] initWithURL:optionsFile device:device width:width height:height
        definitions:@{} includeDirectories:@[includeDirectory] error:&error]&&error.localizedDescription.length>0,
          "missing required compiler definition returns a source diagnostic");
    check([NSFileManager.defaultManager removeItemAtURL:temporary error:&error],"temporary compiler fixture is removed after loading");

    // Effects are independent instances and execute in the exact host-supplied order.
    MSFXEffect *chainGrade=load(root,@"Effects/ColorGrade.fx",device,&error);
    MSFXEffect *chainVibrance=load(root,@"Effects/SweetFX/Vibrance.fx",device,&error);
    check(chainGrade!=nil&&chainVibrance!=nil&&chainGrade!=chainVibrance,"two separate chain effects are loaded");
    NSMutableArray<MSFXEffect *> *mutableChain=[NSMutableArray arrayWithObjects:chainGrade,chainVibrance,nil];
    MSSetFXEffects(mutableChain);
    NSArray<MSFXEffect *> *chain=MSGetFXEffects();
    [mutableChain removeAllObjects];
    check(chain.count==2&&chain[0]==chainGrade&&chain[1]==chainVibrance&&MSGetFXEffects().count==2,
          "effect-chain setter preserves order and copies the caller's mutable array");
    check(MSGetFXEffect()==chainGrade,"legacy single-effect getter returns the first chain effect");
    upload(target,input);
    id<MTLCommandBuffer> chainedBuffer=[queue commandBufferWithUnretainedReferences];
    for(MSFXEffect *entry in chain)
        check([entry encodeCommandBuffer:chainedBuffer texture:target time:1.25 error:&error],"each ordered chain entry encodes onto the same command buffer");
    [chainedBuffer commit];[chainedBuffer waitUntilCompleted];
    check(chainedBuffer.status==MTLCommandBufferStatusCompleted&&
          difference(download(target),vibranced(exposed(input,.5)))<=2,
          "ordered effect chain matches exposure followed by vibrance on the GPU");
    MSSetFXEffect(chainVibrance);
    check(MSGetFXEffects().count==1&&MSGetFXEffect()==chainVibrance&&chain.count==2,
          "legacy setter replaces the chain and existing snapshots remain stable");
    MSSetFXEffects(@[]);
    check(MSGetFXEffects().count==0&&MSGetFXEffect()==nil,"an empty effect chain removes every active FX effect");

    MTLTextureDescriptor *mipped=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:YES];
    mipped.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    error=nil;
    check(![effect encodeCommandBuffer:[queue commandBuffer] texture:[device newTextureWithDescriptor:mipped] time:0 error:&error]&&error!=nil,
          "mipmapped input is rejected before encoding an invalid copy");

    error = nil;
    MSFXEffect *twoPass = load(root, @"Effects/TwoPass.fx", device, &error);
    if (!twoPass) fprintf(stderr, "Multipass compile error: %s\n", error.localizedDescription.UTF8String);
    check(twoPass != nil, "two-pass effect with named intermediate compiles");
    upload(target, input);
    check(render(twoPass, queue, target), "multipass render completes");
    auto multipassExpected = exposed(exposed(input, 0.5), 0.5);
    check(difference(download(target), multipassExpected) <= 2,
          "second pass reads first pass RGBA8 result with expected quantization and alpha");

    error = nil;
    check(![effect encodeCommandBuffer:[queue commandBuffer] texture:makeTexture(device, width + 1, height)
                                  time:0 error:&error] && error.localizedDescription.length > 0,
          "frame-size mismatch is rejected instead of stretching compile-time BUFFER dimensions");
    id<MTLCommandBuffer> committed = [queue commandBuffer];
    [committed commit]; [committed waitUntilCompleted];
    error = nil;
    check(![effect encodeCommandBuffer:committed texture:target time:0 error:&error] && error.localizedDescription.length > 0,
          "already committed command buffer is rejected");

    MSFXEffect *depthRequired=load(root,@"Tests/Fixtures/DepthUnsupported.fx",device,&error);
    check(depthRequired!=nil&&depthRequired.requiresDepth,"DEPTH effects compile and declare their required per-frame input");
    error=nil;
    check(![depthRequired encodeCommandBuffer:[queue commandBuffer] texture:target time:0 error:&error]&&
          [error.localizedDescription.lowercaseString containsString:@"depth"],"DEPTH effects fail explicitly when no depth input is supplied");

    for (NSString *name in @[@"Malformed", @"ComputeUnsupported"]) {
        error = nil;
        MSFXEffect *unsupported = load(root, [@"Tests/Fixtures/" stringByAppendingString:[name stringByAppendingString:@".fx"]], device, &error);
        check(unsupported == nil && error.localizedDescription.length > 0, "invalid or unsupported effect returns compile diagnostics");
        NSString *message = error.localizedDescription.lowercaseString;
        if ([name isEqualToString:@"ComputeUnsupported"])
            check([message containsString:@"compute"], "compute techniques are explicitly rejected");
    }

    error = nil;
    MSFXEffect *historyEffect = load(root, @"Tests/Fixtures/HistoryUnsupported.fx", device, &error);
    check(historyEffect != nil && error == nil, "history/temporal textures compile successfully");

    // A single reusable effect must isolate intermediates across in-flight queues.
    auto parallelPassed = std::make_shared<std::atomic<bool>>(true);
    dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) { @autoreleasepool {
        id<MTLCommandQueue> localQueue = [device newCommandQueue];
        id<MTLTexture> localTarget = makeTexture(device);
        auto localInput = gradient();
        for (size_t i = 0; i < localInput.size(); ++i) if (i % 4 != 3) localInput[i] += uint8_t(index * 3);
        upload(localTarget, localInput);
        if (!render(twoPass, localQueue, localTarget, true) ||
            difference(download(localTarget), exposed(exposed(localInput, 0.5), 0.5)) > 2) parallelPassed->store(false);
    }});
    check(parallelPassed->load(), "shared multipass effect is safe across concurrent queues and unretained buffers");
    printf("PASS: %d FX GPU checks on %s\n", checks, device.name.UTF8String);
    return 0;
}}
