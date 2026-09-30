#import <Foundation/Foundation.h>
#import "FXChain.h"
#include <cmath>
#include <cstdio>

static NSUInteger checks = 0, failures = 0;
static void Check(BOOL passed, NSString *name) {
    ++checks;
    if (!passed) { ++failures; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}
static MSFXPreset *Parse(NSString *source) {
    NSError *error = nil; MSFXPreset *preset = [MSFXPreset presetWithString:source error:&error];
    if (!preset) fprintf(stderr, "Unexpected parse failure: %s\n", error.localizedDescription.UTF8String);
    return preset;
}
static BOOL Reject(NSString *source, NSString *message) {
    NSError *error = nil;
    return [MSFXPreset presetWithString:source error:&error] == nil && [error.localizedDescription containsString:message];
}
int main(void) {
    @autoreleasepool {
        MSFXPreset *preset = Parse(@"\uFEFF; example\r\n# comment\r\n// comment\r\nTechniques=ColorGrade@ColorGrade.fx,Vibrance@Vibrance.fx\r\nTechniqueSorting=Vibrance@Vibrance.fx,Copy@ColorGrade.fx,ColorGrade@ColorGrade.fx\r\nPreprocessorDefinitions=QUALITY=2,VECTOR=float2(1,,2),FLAG\r\n\r\n[ColorGrade.fx]\r\nExposure=-0.25\r\nSaturation=1.1\r\n[ColorGrade.fx]\r\nTestVector=true,FALSE,2e-3,-4\r\nPreprocessorDefinitions=MODE=3\r\n[Vibrance.fx]\r\nVibrance=0.15\r\n");
        Check(preset != nil, @"UTF-8 BOM, CRLF and comment lines parse");
        Check(preset.entries.count == 3 && [preset.entries[0][@"technique"] isEqual:@"Vibrance"] && [preset.entries[2][@"technique"] isEqual:@"ColorGrade"], @"TechniqueSorting preserves execution order");
        Check([preset.entries[0][@"enabled"] boolValue] && ![preset.entries[1][@"enabled"] boolValue] && [preset.entries[2][@"enabled"] boolValue], @"Sorting list retains disabled techniques");
        Check([preset.uniformValues[@"ColorGrade.fx"][@"Exposure"][0] doubleValue] == -0.25 && [preset.uniformValues[@"ColorGrade.fx"][@"TestVector"] count] == 4, @"Repeated effect sections merge values");
        Check([preset.uniformValues[@"ColorGrade.fx"][@"TestVector"][0] boolValue] && ![preset.uniformValues[@"ColorGrade.fx"][@"TestVector"][1] boolValue] && [preset.uniformValues[@"ColorGrade.fx"][@"TestVector"][2] doubleValue] == 0.002, @"Booleans and scientific notation retain values");
        Check([preset.definitions[@"QUALITY"] isEqual:@"2"] && [preset.definitions[@"VECTOR"] isEqual:@"float2(1,2)"] && [preset.definitions[@"FLAG"] isEqual:@""], @"Global definitions and ReShade escaped commas parse");
        Check([preset.effectDefinitions[@"ColorGrade.fx"][@"MODE"] isEqual:@"3"], @"Per-effect definitions parse");
        NSError *error = nil;
        NSString *encoded = [MSFXPreset stringWithEntries:preset.entries uniformValues:preset.uniformValues definitions:preset.definitions effectDefinitions:preset.effectDefinitions error:&error];
        MSFXPreset *roundtrip = encoded ? Parse(encoded) : nil;
        Check(roundtrip != nil && [roundtrip.entries isEqual:preset.entries], @"Export and import retain technique order and state");
        Check([roundtrip.uniformValues isEqual:preset.uniformValues], @"Export and import retain uniform values");
        Check([roundtrip.definitions isEqual:preset.definitions] && [roundtrip.effectDefinitions isEqual:preset.effectDefinitions], @"Definitions round-trip with literal commas and empty replacements");
        MSFXPreset *repeated = Parse(@"Techniques=A@A.fx\nTechniques=B@B.fx\n[A.fx]\nVector=1,2\nVector=3,4\n");
        Check(repeated.entries.count == 2 && [repeated.uniformValues[@"A.fx"][@"Vector"] isEqual:@[@1,@2,@3,@4]], @"Repeated keys append values as ReShade does");
        MSFXPreset *legacy = Parse(@"Techniques=ColorGrade\nTechniqueSorting=Copy,ColorGrade\n");
        Check([legacy.entries[1][@"file"] isEqual:@""] && [legacy.entries[1][@"enabled"] boolValue] && legacy.warnings.count > 0, @"Legacy references preserve unresolved filenames with warning");
        MSFXPreset *qualified = Parse(@"Techniques=ColorGrade@ColorGrade.fx\nTechniqueSorting=Copy@ColorGrade.fx,ColorGrade\n");
        Check(qualified.entries.count == 2 && [qualified.entries[1][@"file"] isEqual:@"ColorGrade.fx"] && [qualified.entries[1][@"enabled"] boolValue], @"Qualified enabled entry uses legacy sorting position");
        MSFXPreset *wildcard = Parse(@"Techniques=A\nTechniqueSorting=A@One.fx,A@Two.fx\n");
        Check(wildcard.entries.count == 2 && [wildcard.entries[0][@"enabled"] boolValue] && [wildcard.entries[1][@"enabled"] boolValue], @"Legacy enabled name enables all qualified matches");
        MSFXPreset *appended = Parse(@"Techniques=B@B.fx,A@A.fx\nTechniqueSorting=A@A.fx,C@C.fx\n");
        Check(appended.entries.count == 3 && [appended.entries[2][@"technique"] isEqual:@"B"], @"Enabled techniques absent from sorting append in enabled order");
        MSFXPreset *dedup = Parse(@"Techniques=A@A.fx,A@A.fx\nTechniqueSorting=A@A.fx,A@A.fx\n");
        Check(dedup.entries.count == 1 && dedup.warnings.count == 2, @"Duplicate references merge with warnings");
        MSFXPreset *empty = Parse(@"Techniques=\nTechniqueSorting=A@A.fx\n");
        Check(empty.entries.count == 1 && ![empty.entries[0][@"enabled"] boolValue], @"Explicitly empty Techniques supports a disabled preset");
        MSFXPreset *none = Parse(@"Techniques=\n");
        Check(none.entries.count == 0, @"Empty preset contains no fabricated effects");
        MSFXPreset *extras = Parse(@"Techniques=A@A.fx\nKeyA@A.fx=36,0,0,0\n[GENERAL]\nUnused=anything\n");
        Check(extras.warnings.count == 2 && extras.uniformValues.count == 0, @"Unknown globals and non-effect sections are reported");
        MSFXPreset *commaName = Parse(@"Techniques=A@A,, B.fx\n[A, B.fx]\nValue=1\n");
        Check([commaName.entries[0][@"file"] isEqual:@"A, B.fx"], @"Escaped commas in filenames use ReShade list syntax");
        Check(Reject(@"[GENERAL]\nTechniques=A\n", @"root Techniques="), @"Configuration INI is rejected without root Techniques");
        Check(Reject(@"Techniques=A@../A.fx\n", @"invalid technique reference"), @"Effect references cannot traverse directories");
        Check(Reject(@"Techniques=A@A.fx,\n", @"invalid technique reference"), @"Malformed trailing list delimiter is actionable");
        Check(Reject(@"Techniques=A\n[A.fx]\nValue=1,invalid\n", @"invalid numeric value 'invalid'"), @"Invalid vector component rejects whole preset");
        Check(Reject(@"Techniques=A\n[A.fx]\nValue=nan\n", @"invalid numeric value"), @"NaN is rejected");
        Check(Reject(@"Techniques=A\n[A.fx]\nValue=1e400\n", @"invalid numeric value"), @"Numeric overflow is rejected");
        Check(Reject(@"Techniques=A\n[A.fx]\nValue=\n", @"requires 1–16"), @"Empty uniform does not silently become zero");
        Check(Reject(@"Techniques=A\r\n[A.fx]\r\nValue=wat\r\n", @"Line 3:"), @"CRLF error reports correct physical line");
        Check(Reject(@"Techniques=A\n[A.fx]\nValue=1 ; inline comment\n", @"invalid numeric value"), @"Unsupported inline comment is not silently truncated");
        Check(Reject(@"Techniques=A\n[A.fx\nValue=1\n", @"malformed [section]"), @"Malformed section is rejected");
        Check(Reject(@"Techniques=A\nPreprocessorDefinitions=MODE=1,MODE=2\n", @"conflicting values"), @"Conflicting definitions are rejected");
        Check(Reject(@"Techniques=A\nPreprocessorDefinitions=BAD-NAME=1\n", @"invalid preprocessor definition"), @"Invalid macro names are rejected");
        Check(Reject(@"Techniques=A\n[../A.fx]\nX=1\n", @"without a directory path"), @"Effect section paths are rejected");
        NSMutableArray *many = [NSMutableArray array]; for (NSUInteger i = 0; i < 513; ++i) [many addObject:[NSString stringWithFormat:@"T%lu@A.fx", (unsigned long)i]];
        Check(Reject([@"Techniques=" stringByAppendingString:[many componentsJoinedByString:@","]], @"512-technique"), @"Technique count limit is enforced");
        Check(Reject([@"Techniques=\n;" stringByPaddingToLength:1024*1024+1 withString:@"x" startingAtIndex:0], @"1 MiB"), @"File size limit is enforced");
        Check([MSFXPreset stringWithEntries:@[@{@"technique":@"A",@"file":@"A.fx",@"enabled":@YES},@{@"technique":@"A",@"file":@"A.fx",@"enabled":@NO}] uniformValues:@{} definitions:@{} effectDefinitions:@{} error:&error] == nil, @"Export rejects duplicate technique state");
        Check([MSFXPreset stringWithEntries:@[] uniformValues:@{@"A.fx":@{@"Value":@[@(NAN)]}} definitions:@{} effectDefinitions:@{} error:&error] == nil, @"Export rejects nonfinite values");
        Check([MSFXPreset stringWithEntries:@[] uniformValues:@{} definitions:@{@"MODE":@"1\nTechniques=X"} effectDefinitions:@{} error:&error] == nil, @"Export cannot inject INI lines through definitions");
        Check([MSFXPreset stringWithEntries:@[] uniformValues:@{} definitions:(id)@{@42:@"x"} effectDefinitions:@{} error:&error] == nil, @"Export rejects non-string definition keys safely");
        NSString *precise = [MSFXPreset stringWithEntries:@[] uniformValues:@{@"A.fx":@{@"Value":@[@(0.12345678901234567)]}} definitions:@{} effectDefinitions:@{} error:&error];
        Check([Parse(precise).uniformValues[@"A.fx"][@"Value"][0] doubleValue] == 0.12345678901234567, @"Floating point values round-trip without precision loss");
        NSURL *temp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"MacShade-preset-%@.ini", NSUUID.UUID.UUIDString]]];
        [encoded writeToURL:temp atomically:YES encoding:NSUTF8StringEncoding error:&error];
        Check([[MSFXPreset presetWithURL:temp error:&error].entries isEqual:preset.entries], @"Local UTF-8 file import works");
        const uint8_t invalid[] = {0xff, 0xfe, 0xfa}; [[NSData dataWithBytes:invalid length:sizeof(invalid)] writeToURL:temp atomically:YES];
        Check([MSFXPreset presetWithURL:temp error:&error] == nil && [error.localizedDescription containsString:@"UTF-8"], @"Invalid text encoding gets actionable diagnostics");
        [[NSFileManager defaultManager] removeItemAtURL:temp error:NULL];
        Check([MSFXPreset presetWithURL:[NSURL URLWithString:@"https://example.com/preset.ini"] error:&error] == nil && [error.localizedDescription containsString:@"local"], @"Import API accepts local files only");
        NSURL *extraviURL = [NSURL fileURLWithPath:@"Presets/Extravi/Extravi's ReShade-Preset Low-Glossy.ini"];
        if ([NSFileManager.defaultManager fileExistsAtPath:extraviURL.path]) {
            MSFXPreset *extravi = [MSFXPreset presetWithURL:extraviURL error:&error];
            Check(extravi != nil && extravi.entries.count > 0, @"Extravi preset with leading comma in PreprocessorDefinitions parses cleanly");
        }
        NSURL *extraviDirectory = [NSURL fileURLWithPath:@"Presets/Extravi" isDirectory:YES];
        NSArray<NSURL *> *extraviFiles = [[NSFileManager.defaultManager contentsOfDirectoryAtURL:extraviDirectory
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(NSURL *url, __unused NSDictionary *bindings) { return [url.pathExtension.lowercaseString isEqual:@"ini"]; }]];
        NSUInteger parsedExtravi = 0;
        for (NSURL *url in extraviFiles) {
            NSError *presetError = nil;
            if ([MSFXPreset presetWithURL:url error:&presetError]) ++parsedExtravi;
            else fprintf(stderr, "Extravi preset parse failed (%s): %s\n", url.lastPathComponent.UTF8String, presetError.localizedDescription.UTF8String);
        }
        Check(extraviFiles.count == 17 && parsedExtravi == 17, @"All 17 bundled Extravi presets parse from the source collection");
        NSMutableArray<NSDictionary *> *library = [NSMutableArray array];
        NSDirectoryEnumerator *shaderFiles = [NSFileManager.defaultManager enumeratorAtURL:
            [NSURL fileURLWithPath:@"Effects" isDirectory:YES] includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in shaderFiles) if ([url.pathExtension.lowercaseString isEqual:@"fx"])
            [library addObject:@{@"url":url, @"name":url.lastPathComponent.stringByDeletingPathExtension}];
        NSUInteger resolvedExtravi = 0, adaptedBloom = 0, mappedBloomValues = 0, missingActive = 0;
        for (NSURL *url in extraviFiles) {
            NSError *presetError = nil; NSMutableArray<NSString *> *warnings = [NSMutableArray array];
            MSFXPreset *extravi = [MSFXPreset presetWithURL:url error:&presetError];
            NSArray<NSDictionary *> *specs = extravi ? MSFXPresetSpecifications(extravi, url, library, warnings, &presetError) : nil;
            if (!specs) { fprintf(stderr, "Extravi preset resolution failed (%s): %s\n", url.lastPathComponent.UTF8String, presetError.localizedDescription.UTF8String); continue; }
            ++resolvedExtravi; BOOL hasActive = NO;
            for (NSDictionary *spec in specs) {
                if (![spec[@"enabled"] boolValue]) continue;
                hasActive = YES;
                if ([[spec[@"url"] lastPathComponent] isEqual:@"qUINT_bloom.fx"] && [spec[@"technique"] isEqual:@"Bloom"]) {
                    ++adaptedBloom;
                    NSDictionary *values = spec[@"values"];
                    if ([values[@"BLOOM_INTENSITY"][0] doubleValue] == 0.1 &&
                        [values[@"BLOOM_CURVE"][0] doubleValue] == 1.5 &&
                        [values[@"BLOOM_SAT"][0] doubleValue] == 2.0) ++mappedBloomValues;
                }
            }
            if (!hasActive) ++missingActive;
            for (NSString *warning in warnings) if ([warning hasPrefix:@"Skipped unavailable effect:"]) ++missingActive;
        }
        Check(resolvedExtravi == 17 && missingActive == 0, @"Every Extravi preset resolves its enabled shaders from the bundled library");
        Check(adaptedBloom == 9 && mappedBloomValues == 9, @"Nine PPFX bloom presets map to qUINT and retain intensity, curve, and saturation");
        printf("Preset tests: %lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
