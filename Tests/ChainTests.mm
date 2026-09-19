#import <Foundation/Foundation.h>
#import "FXChain.h"
#include <cstdio>
#include <cstdlib>
static int checks=0;
static void Check(BOOL ok, NSString *message) {
    if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);} ++checks;
}
int main() { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); Check(device!=nil,@"Metal device");
    NSURL *root=[NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath];
    NSArray *library=MSFXLibrary(@[[root URLByAppendingPathComponent:@"Effects"],[root URLByAppendingPathComponent:@"Tests/Fixtures"]]);
    NSError *error=nil;
    NSString *ini=@"Techniques=ColorGrade@ColorGrade.fx,Vibrance@Vibrance.fx\nTechniqueSorting=Vibrance@Vibrance.fx,ColorGrade@ColorGrade.fx,Compute@ComputeUnsupported.fx\nPreprocessorDefinitions=GLOBAL_CHECK=7\n[ColorGrade.fx]\nExposure=0.25\nSaturation=0.8\nPreprocessorDefinitions=LOCAL_CHECK=9\n[Vibrance.fx]\nVibrance=0.2\nVibranceRGBBalance=1,0.9,0.8\n";
    MSFXPreset *preset=[MSFXPreset presetWithString:ini error:&error];
    Check(preset!=nil,error.localizedDescription ?: @"Preset parses");
    NSMutableArray *warnings=[NSMutableArray array];
    NSURL *presetURL=[root URLByAppendingPathComponent:@"Presets/test.ini"];
    NSArray *specs=MSFXPresetSpecifications(preset,presetURL,library,warnings,&error);
    Check(specs.count==3,error.localizedDescription ?: @"Resolves ordered active and inactive techniques");
    Check([specs[0][@"technique"] isEqual:@"Vibrance"] && [specs[1][@"technique"] isEqual:@"ColorGrade"],@"TechniqueSorting order");
    Check([specs[1][@"definitions"][@"GLOBAL_CHECK"] isEqual:@"7"] && [specs[1][@"definitions"][@"LOCAL_CHECK"] isEqual:@"9"],@"Global and per-effect definitions merge");
    NSArray *entries=MSCompileFXChain(specs,device,8,8,@[],&error);
    Check(entries.count==3,error.localizedDescription ?: @"Compile complete chain");
    Check(entries[0][@"effect"]!=nil && entries[1][@"effect"]!=nil && entries[2][@"effect"]==nil,@"Inactive compute shader remains uncompiled");
    MSFXEffect *grade=entries[1][@"effect"];
    BOOL restored=NO;
    for(NSDictionary *u in grade.uniforms) if([u[@"name"] isEqual:@"Exposure"]) restored=[u[@"values"][0] doubleValue]==0.25;
    Check(restored,@"Preset uniform values reach compiled effect");
    NSString *saved=MSFXChainPresetString(entries,&error);
    Check(saved!=nil,error.localizedDescription ?: @"Exports current chain");
    MSFXPreset *roundtrip=[MSFXPreset presetWithString:saved error:&error];
    Check(roundtrip.entries.count==3 && ![roundtrip.entries[2][@"enabled"] boolValue],@"INI roundtrip preserves disabled technique");
    Check([roundtrip.uniformValues[@"ColorGrade.fx"][@"Exposure"][0] doubleValue]==0.25,@"INI roundtrip preserves edited numeric value");
    MSSetFXEffects(@[entries[0][@"effect"],grade]);
    NSMutableArray *bad=[MSFXChainSpecifications(entries) mutableCopy];
    NSMutableDictionary *depth=[bad[2] mutableCopy]; depth[@"enabled"]=@YES; bad[2]=depth;
    NSArray *failed=MSCompileFXChain(bad,device,8,8,@[],&error);
    Check(failed==nil && [error.localizedDescription containsString:@"Compute"],@"Enabling unsupported compute effect reports its dependency");
    Check(MSGetFXEffects().count==2 && MSGetFXEffects()[1]==grade,@"Failed replacement leaves installed chain intact");
    MSFXPreset *missing=[MSFXPreset presetWithString:@"Techniques=Missing@NoSuchShader.fx\n" error:&error];
    Check(MSFXPresetSpecifications(missing,presetURL,library,warnings,&error)==nil && [error.localizedDescription containsString:@"Missing shader"],@"Missing active shader has actionable diagnostic");
    MSFXPreset *inactive=[MSFXPreset presetWithString:@"Techniques=\nTechniqueSorting=Missing@NoSuchShader.fx\n" error:&error];
    [warnings removeAllObjects];
    Check(MSFXPresetSpecifications(inactive,presetURL,library,warnings,&error).count==0 && warnings.count==1,@"Missing disabled shader is reported without blocking empty preset");
    NSMutableArray *duplicate=[library mutableCopy];
    [duplicate addObject:@{@"url":[NSURL fileURLWithPath:@"/unresolved/ColorGrade.fx"],@"name":@"ColorGrade",@"subtitle":@"Other"}];
    Check(MSFXPresetSpecifications(preset,presetURL,duplicate,warnings,&error)==nil && [error.localizedDescription containsString:@"multiple"],@"Ambiguous shader filenames are rejected");
    NSMutableArray *invalid=[specs mutableCopy];
    NSMutableDictionary *invalidGrade=[invalid[1] mutableCopy]; invalidGrade[@"values"]=@{@"NoSuchUniform":@[@1]}; invalidGrade[@"strictValues"]=@YES; invalid[1]=invalidGrade;
    Check(MSCompileFXChain(invalid,device,8,8,@[],&error)==nil && [error.localizedDescription containsString:@"NoSuchUniform"],@"Unknown preset parameter rejected before chain install");
    MSFXPreset *reversed=[MSFXPreset presetWithString:@"Techniques=ColorGrade@ColorGrade.fx\nPreprocessorDefinitions=RESHADE_DEPTH_INPUT_IS_REVERSED=1\n" error:&error];
    [warnings removeAllObjects];
    NSArray *adapted=MSFXPresetSpecifications(reversed,presetURL,library,warnings,&error);
    Check([adapted[0][@"definitions"][@"RESHADE_DEPTH_INPUT_IS_REVERSED"] isEqual:@"0"] && warnings.count==1,@"Preset depth convention adapts to normalized forward input with a notice");
    NSMutableDictionary *withHotkey=[specs[1] mutableCopy];
    withHotkey[@"values"]=@{@"Exposure":@[@0.4],@"KeyExposure":@[@36,@0,@0,@0]};
    Check(MSCompileFXChain(@[withHotkey],device,8,8,@[],&error)!=nil,@"ReShade hotkey metadata is not mistaken for a shader uniform");

    NSURL *extraviURL=[root URLByAppendingPathComponent:@"Presets/Extravi/Extravi's ReShade-Preset Low.ini"];
    MSFXPreset *extraviPreset=[MSFXPreset presetWithURL:extraviURL error:&error];
    Check(extraviPreset!=nil,error.localizedDescription ?: @"Extravi Low preset parses");
    [warnings removeAllObjects];
    NSArray *extraviSpecs=MSFXPresetSpecifications(extraviPreset,extraviURL,library,warnings,&error);
    Check(extraviSpecs.count>=10,error.localizedDescription ?: @"Extravi Low specs resolve");
    Check(warnings.count>0 && [warnings[0] containsString:@"PPFX_Bloom.fx"],@"Missing PPFX_Bloom is reported as warning without blocking preset");
    NSArray *incDirs=@[[root URLByAppendingPathComponent:@"Effects"],[root URLByAppendingPathComponent:@"Effects/Textures"]];
    NSArray *extraviEntries=MSCompileFXChain(extraviSpecs,device,64,64,incDirs,&error);
    Check(extraviEntries.count==extraviSpecs.count,error.localizedDescription ?: @"Extravi Low effects compile successfully");

    MSSetFXEffects(@[]);
    printf("PASS: %d preset-chain checks on %s\n",checks,device.name.UTF8String);
    return 0;
} }
