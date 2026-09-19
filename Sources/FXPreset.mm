#import "FXPreset.h"
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <xlocale.h>

static constexpr NSUInteger MSPresetMaxBytes = 1024 * 1024;
static constexpr NSUInteger MSPresetMaxEntries = 512;
static constexpr NSUInteger MSPresetMaxEffects = 256;
static constexpr NSUInteger MSPresetMaxKeys = 4096;

static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"MacShade.Preset" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static NSString *Trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static BOOL Identifier(NSString *s, BOOL namespaced) {
    if (![s isKindOfClass:NSString.class] || s.length == 0 || s.length > 256) return NO;
    NSArray *parts = namespaced ? [s componentsSeparatedByString:@"::"] : @[s];
    for (NSString *part in parts) {
        if (part.length == 0) return NO;
        for (NSUInteger i = 0; i < part.length; ++i) {
            const unichar c = [part characterAtIndex:i];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (i && c >= '0' && c <= '9'))) return NO;
        }
    }
    return YES;
}
static BOOL FileName(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length == 0 || s.length > 255 || ![s isEqualToString:Trim(s)] ||
        ![s.pathExtension.lowercaseString isEqualToString:@"fx"]) return NO;
    return [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:[]\r\n\t"]].location == NSNotFound &&
           [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSString *Escape(NSString *s) { return [s stringByReplacingOccurrencesOfString:@"," withString:@",,"]; }
// ReShade escapes a literal comma with a second comma, rather than quoting CSV.
static NSArray<NSString *> *Split(NSString *value) {
    if (value.length == 0) return @[];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableString *part = [NSMutableString string];
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c == ',' && i + 1 < value.length && [value characterAtIndex:i + 1] == ',') {
            [part appendString:@","]; ++i;
        } else if (c == ',') {
            [result addObject:Trim(part)]; [part setString:@""];
        } else [part appendFormat:@"%C", c];
    }
    [result addObject:Trim(part)];
    return result;
}
static NSDictionary *Reference(NSString *raw, NSString *context, NSError **error) {
    NSRange at = [raw rangeOfString:@"@"];
    NSString *technique = at.location == NSNotFound ? raw : [raw substringToIndex:at.location];
    NSString *file = at.location == NSNotFound ? @"" : [raw substringFromIndex:at.location + 1];
    if (!Identifier(technique, YES) || (at.location != NSNotFound && !FileName(file))) {
        Fail(error, [NSString stringWithFormat:@"%@: invalid technique reference '%@'. Use Technique@Effect.fx or a technique name.", context, raw]);
        return nil;
    }
    return @{@"technique": technique, @"file": file};
}
static NSString *ReferenceKey(NSDictionary *ref) {
    return [ref[@"file"] length] ? [NSString stringWithFormat:@"%@@%@", ref[@"technique"], ref[@"file"]] : ref[@"technique"];
}
static NSDictionary *ParseDefinitions(NSArray<NSString *> *values, NSString *context, NSError **error) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *item in values) {
        if (Trim(item).length == 0) continue;
        NSRange equals = [item rangeOfString:@"="];
        NSString *name = Trim(equals.location == NSNotFound ? item : [item substringToIndex:equals.location]);
        NSString *value = equals.location == NSNotFound ? @"" : Trim([item substringFromIndex:equals.location + 1]);
        if (!Identifier(name, NO) || value.length > 4096 || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            Fail(error, [NSString stringWithFormat:@"%@: invalid preprocessor definition '%@'. Expected NAME or NAME=value.", context, item]);
            return nil;
        }
        if (result[name] && ![result[name] isEqualToString:value]) {
            Fail(error, [NSString stringWithFormat:@"%@: preprocessor definition %@ has conflicting values.", context, name]);
            return nil;
        }
        result[name] = value;
    }
    return result;
}
static NSNumber *Number(NSString *s) {
    if ([s caseInsensitiveCompare:@"true"] == NSOrderedSame) return @YES;
    if ([s caseInsensitiveCompare:@"false"] == NSOrderedSame) return @NO;
    static NSRegularExpression *syntax;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ syntax = [NSRegularExpression regularExpressionWithPattern:@"^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$" options:0 error:NULL]; });
    if (s.length == 0 || s.length > 128 || [syntax numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] != 1) return nil;
    static locale_t locale = newlocale(LC_NUMERIC_MASK, "C", nullptr);
    const char *start = s.UTF8String; char *end = nullptr;
    errno = 0; const double value = strtod_l(start, &end, locale);
    if (errno == ERANGE || !std::isfinite(value) || end == start || *end) return nil;
    return @(value);
}

@interface MSFXPreset ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *entries;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSNumber *> *> *> *uniformValues;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *definitions;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *effectDefinitions;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *warnings;
@end

@implementation MSFXPreset
+ (instancetype)presetWithURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) { Fail(error, @"Choose a local ReShade .ini preset file."); return nil; }
    // Read at most one extra byte so even a growing file cannot cause unbounded allocation.
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (!handle) return nil;
    NSData *data = [handle readDataUpToLength:MSPresetMaxBytes + 1 error:error];
    [handle closeAndReturnError:NULL];
    if (!data) return nil;
    if (data.length > MSPresetMaxBytes) { Fail(error, @"Preset exceeds the 1 MiB import limit."); return nil; }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { Fail(error, @"Preset must use UTF-8 text encoding. Save it as UTF-8 and try again."); return nil; }
    return [self presetWithString:text error:error];
}
+ (instancetype)presetWithString:(NSString *)text error:(NSError **)error {
    if (![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > MSPresetMaxBytes) {
        Fail(error, @"Preset exceeds the 1 MiB import limit."); return nil;
    }
    if (text.length && [text characterAtIndex:0] == 0xfeff) text = [text substringFromIndex:1];
    NSCharacterSet *disallowed = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)];
    if ([text rangeOfCharacterFromSet:disallowed].location != NSNotFound) { Fail(error, @"Preset contains a NUL character and is not valid INI text."); return nil; }
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > 32768) { Fail(error, @"Preset exceeds the 32,768-line import limit."); return nil; }
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *> *sections = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *locations = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSString *section = @""; sections[section] = [NSMutableDictionary dictionary];
    NSUInteger keyCount = 0, lineNumber = 0;
    for (NSString *untrimmed in lines) {
        ++lineNumber; NSString *line = Trim(untrimmed);
        if (line.length == 0 || [@[@";", @"#", @"/"] containsObject:[line substringToIndex:1]]) continue;
        if (line.length > 65536) { Fail(error, [NSString stringWithFormat:@"Line %lu exceeds the 64 KiB line limit.", (unsigned long)lineNumber]); return nil; }
        if ([line hasPrefix:@"["]) {
            if (![line hasSuffix:@"]"] || [[line substringFromIndex:1] containsString:@"["] || [[line substringToIndex:line.length - 1] containsString:@"]"]) {
                Fail(error, [NSString stringWithFormat:@"Line %lu: malformed [section] heading.", (unsigned long)lineNumber]); return nil;
            }
            section = Trim([line substringWithRange:NSMakeRange(1, line.length - 2)]);
            if (section.length == 0 || section.length > 255) { Fail(error, [NSString stringWithFormat:@"Line %lu: empty or overly long section name.", (unsigned long)lineNumber]); return nil; }
            if (!sections[section]) sections[section] = [NSMutableDictionary dictionary];
            if (sections.count > MSPresetMaxEffects + 1) { Fail(error, @"Preset exceeds the 256-section import limit."); return nil; }
            continue;
        }
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound) { Fail(error, [NSString stringWithFormat:@"Line %lu: expected key=value.", (unsigned long)lineNumber]); return nil; }
        NSString *key = Trim([line substringToIndex:equals.location]);
        if (key.length == 0 || key.length > 512) { Fail(error, [NSString stringWithFormat:@"Line %lu: empty or overly long key.", (unsigned long)lineNumber]); return nil; }
        NSString *value = Trim([line substringFromIndex:equals.location + 1]);
        NSMutableArray *elements = sections[section][key];
        if (!elements) {
            elements = [NSMutableArray array]; sections[section][key] = elements;
            locations[[NSString stringWithFormat:@"%@\n%@", section, key]] = @(lineNumber);
            if (++keyCount > MSPresetMaxKeys) { Fail(error, @"Preset exceeds the 4,096-key import limit."); return nil; }
        }
        [elements addObjectsFromArray:Split(value)];
        if (elements.count > 1024) { Fail(error, [NSString stringWithFormat:@"Line %lu: %@ exceeds the 1,024-value limit.", (unsigned long)lineNumber, key]); return nil; }
    }
    NSDictionary *global = sections[@""];
    if (!global[@"Techniques"]) { Fail(error, @"This is not a ReShade effect preset: a root Techniques= line is required. Choose a preset .ini rather than ReShade's configuration file."); return nil; }
    NSMutableArray<NSDictionary *> *enabled = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *ordered = [NSMutableArray array];
    NSMutableSet *enabledKeys = [NSMutableSet set], *orderKeys = [NSMutableSet set];
    for (NSString *key in @[@"Techniques", @"TechniqueSorting"]) {
        NSUInteger line = [locations[[NSString stringWithFormat:@"\n%@", key]] unsignedIntegerValue];
        for (NSString *item in global[key]) {
            NSDictionary *reference = Reference(item, [NSString stringWithFormat:@"Line %lu (%@)", (unsigned long)line, key], error);
            if (!reference) return nil;
            NSMutableArray *target = [key isEqualToString:@"Techniques"] ? enabled : ordered;
            NSMutableSet *keys = [key isEqualToString:@"Techniques"] ? enabledKeys : orderKeys;
            if (![keys containsObject:ReferenceKey(reference)]) { [target addObject:reference]; [keys addObject:ReferenceKey(reference)]; }
            else [warnings addObject:[NSString stringWithFormat:@"Duplicate %@ reference %@ was merged.", key, item]];
        }
    }
    if (ordered.count == 0) [ordered addObjectsFromArray:enabled];
    // Resolve qualified enabled entries into legacy ordering slots where possible.
    NSMutableArray *resolvedOrder = [NSMutableArray array];
    for (NSDictionary *sortRef in ordered) {
        BOOL replaced = NO;
        if ([sortRef[@"file"] length] == 0) {
            for (NSDictionary *onRef in enabled) {
                if ([onRef[@"file"] length] && [onRef[@"technique"] isEqual:sortRef[@"technique"]]) {
                    [resolvedOrder addObject:onRef]; replaced = YES;
                }
            }
        }
        if (!replaced) [resolvedOrder addObject:sortRef];
    }
    for (NSDictionary *onRef in enabled) {
        BOOL present = NO;
        for (NSDictionary *sortRef in resolvedOrder) {
            if ([ReferenceKey(onRef) isEqual:ReferenceKey(sortRef)] ||
                ([onRef[@"file"] length] == 0 && [onRef[@"technique"] isEqual:sortRef[@"technique"]])) { present = YES; break; }
        }
        if (!present) [resolvedOrder addObject:onRef];
    }
    NSMutableArray *entries = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *ref in resolvedOrder) {
        NSString *key = ReferenceKey(ref); if ([seen containsObject:key]) continue; [seen addObject:key];
        BOOL isEnabled = [enabledKeys containsObject:key] || [enabledKeys containsObject:ref[@"technique"]];
        [entries addObject:@{@"technique": ref[@"technique"], @"file": ref[@"file"], @"enabled": @(isEnabled)}];
    }
    if (entries.count > MSPresetMaxEntries) { Fail(error, @"Preset exceeds the 512-technique import limit."); return nil; }
    for (NSDictionary *entry in entries) if ([entry[@"file"] length] == 0) {
        [warnings addObject:@"This preset uses legacy technique names without effect filenames. MacShade must resolve these against the selected effect library."]; break;
    }
    NSDictionary *definitions = ParseDefinitions(global[@"PreprocessorDefinitions"] ?: @[], @"Global PreprocessorDefinitions", error);
    if (!definitions) return nil;
    for (NSString *key in [[global allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![@[@"Techniques", @"TechniqueSorting", @"PreprocessorDefinitions"] containsObject:key])
            [warnings addObject:[NSString stringWithFormat:@"Global preset field %@ is not used by MacShade.", key]];
    }
    NSMutableDictionary *uniformValues = [NSMutableDictionary dictionary], *effectDefinitions = [NSMutableDictionary dictionary];
    for (NSString *file in [[sections allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (file.length == 0) continue;
        if (![file.pathExtension.lowercaseString isEqualToString:@"fx"]) {
            [warnings addObject:[NSString stringWithFormat:@"Section [%@] is not an effect section and was ignored.", file]]; continue;
        }
        if (!FileName(file)) { Fail(error, [NSString stringWithFormat:@"Effect section [%@] must use an effect filename without a directory path.", file]); return nil; }
        NSDictionary *values = sections[file]; NSMutableDictionary *uniforms = [NSMutableDictionary dictionary];
        NSDictionary *effectDefs = ParseDefinitions(values[@"PreprocessorDefinitions"] ?: @[], [NSString stringWithFormat:@"[%@] PreprocessorDefinitions", file], error);
        if (!effectDefs) return nil;
        if (effectDefs.count) effectDefinitions[file] = effectDefs;
        for (NSString *key in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if ([key isEqualToString:@"PreprocessorDefinitions"]) continue;
            NSUInteger line = [locations[[NSString stringWithFormat:@"%@\n%@", file, key]] unsignedIntegerValue];
            if (!Identifier(key, YES)) { Fail(error, [NSString stringWithFormat:@"Line %lu: invalid uniform name %@ in [%@].", (unsigned long)line, key, file]); return nil; }
            NSArray *components = values[key];
            if (components.count == 0 || components.count > 16) { Fail(error, [NSString stringWithFormat:@"Line %lu: %@ in [%@] requires 1–16 numeric values.", (unsigned long)line, key, file]); return nil; }
            NSMutableArray *numbers = [NSMutableArray array];
            for (NSString *component in components) {
                NSNumber *number = Number(component);
                if (!number) { Fail(error, [NSString stringWithFormat:@"Line %lu: %@ in [%@] contains invalid numeric value '%@'. Use finite numbers or true/false, separated by commas.", (unsigned long)line, key, file, component]); return nil; }
                [numbers addObject:number];
            }
            uniforms[key] = [numbers copy];
        }
        if (uniforms.count) uniformValues[file] = [uniforms copy];
    }
    MSFXPreset *preset = [self new];
    preset.entries = entries; preset.uniformValues = uniformValues; preset.definitions = definitions;
    preset.effectDefinitions = effectDefinitions; preset.warnings = warnings;
    return preset;
}
+ (NSString *)stringWithEntries:(NSArray<NSDictionary *> *)entries
                 uniformValues:(NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSNumber *> *> *> *)uniformValues
                   definitions:(NSDictionary<NSString *, NSString *> *)definitions
             effectDefinitions:(NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)effectDefinitions
                         error:(NSError **)error {
    if (![entries isKindOfClass:NSArray.class] || entries.count > MSPresetMaxEntries ||
        ![uniformValues isKindOfClass:NSDictionary.class] || ![definitions isKindOfClass:NSDictionary.class] || ![effectDefinitions isKindOfClass:NSDictionary.class]) {
        Fail(error, @"Preset export requires at most 512 technique entries and valid parameter/definition dictionaries."); return nil;
    }
    NSMutableArray *enabled = [NSMutableArray array], *ordered = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class] || !Identifier(entry[@"technique"], YES) ||
            ![entry[@"file"] isKindOfClass:NSString.class] || ([entry[@"file"] length] && !FileName(entry[@"file"])) ||
            ![entry[@"enabled"] isKindOfClass:NSNumber.class] || !std::isfinite([entry[@"enabled"] doubleValue])) {
            Fail(error, @"An exported technique entry has an invalid name, filename, or enabled value."); return nil;
        }
        NSString *key = ReferenceKey(entry);
        if ([seen containsObject:key]) { Fail(error, [NSString stringWithFormat:@"Cannot export duplicate technique %@.", key]); return nil; }
        [seen addObject:key]; [ordered addObject:Escape(key)];
        if ([entry[@"enabled"] boolValue]) [enabled addObject:Escape(key)];
    }
    NSMutableString *output = [NSMutableString stringWithFormat:@"; MacShade ReShade preset\nTechniques=%@\nTechniqueSorting=%@\n", [enabled componentsJoinedByString:@","], [ordered componentsJoinedByString:@","]];
    BOOL (^appendDefinitions)(NSDictionary *, NSString *, NSError **) = ^BOOL(NSDictionary *dict, NSString *context, NSError **definitionError) {
        if (![dict isKindOfClass:NSDictionary.class] || dict.count > 1024) return Fail(definitionError, [context stringByAppendingString:@": invalid preprocessor definition dictionary."]);
        // Check keys before sorting to avoid sending compare: to a non-string object.
        for (id key in dict) if (!Identifier(key, NO) || ![dict[key] isKindOfClass:NSString.class]) return Fail(definitionError, [context stringByAppendingString:@": definitions must map C identifiers to strings."]);
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *key in [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *value = dict[key];
            if (value.length > 4096 || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound || ![value isEqual:Trim(value)])
                return Fail(definitionError, [NSString stringWithFormat:@"%@: invalid replacement value for %@.", context, key]);
            [items addObject:Escape(value.length ? [NSString stringWithFormat:@"%@=%@", key, value] : key)];
        }
        if (items.count) [output appendFormat:@"PreprocessorDefinitions=%@\n", [items componentsJoinedByString:@","]];
        return YES;
    };
    if (!appendDefinitions(definitions, @"Global definitions", error)) return nil;
    NSMutableSet *files = [NSMutableSet setWithArray:uniformValues.allKeys]; [files addObjectsFromArray:effectDefinitions.allKeys];
    if (files.count > MSPresetMaxEffects) { Fail(error, @"Preset exceeds the 256-effect export limit."); return nil; }
    for (id file in files) if (!FileName(file)) { Fail(error, @"Effect sections must use .fx filenames without directory paths."); return nil; }
    NSUInteger keyCount = 0;
    for (NSString *file in [[files allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        [output appendFormat:@"\n[%@]\n", file];
        if (!appendDefinitions(effectDefinitions[file] ?: @{}, file, error)) return nil;
        NSDictionary *uniforms = uniformValues[file] ?: @{};
        if (![uniforms isKindOfClass:NSDictionary.class]) { Fail(error, @"Uniform values must be dictionaries of numeric arrays."); return nil; }
        for (id key in uniforms) if (!Identifier(key, YES) || [key isEqual:@"PreprocessorDefinitions"]) { Fail(error, @"Invalid or reserved uniform name in preset export."); return nil; }
        for (NSString *key in [[uniforms allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if (++keyCount > MSPresetMaxKeys) { Fail(error, @"Preset exceeds the 4,096-key export limit."); return nil; }
            NSArray *values = uniforms[key];
            if (![values isKindOfClass:NSArray.class] || values.count == 0 || values.count > 16) { Fail(error, @"Each uniform requires 1–16 numeric values."); return nil; }
            NSMutableArray *encoded = [NSMutableArray array];
            for (id value in values) {
                if (![value isKindOfClass:NSNumber.class] || !std::isfinite([value doubleValue])) { Fail(error, @"Uniform export requires finite numeric values."); return nil; }
                // Seventeen significant digits preserve every finite double.
                static locale_t numericLocale = newlocale(LC_NUMERIC_MASK, "C", nullptr);
                char buffer[64]; snprintf_l(buffer,sizeof(buffer),numericLocale,"%.17g",[value doubleValue]);
                [encoded addObject:[NSString stringWithUTF8String:buffer]];
            }
            [output appendFormat:@"%@=%@\n", key, [encoded componentsJoinedByString:@","]];
        }
    }
    // The same bounded parser verifies that the emitted file is importable.
    if (![self presetWithString:output error:error]) return nil;
    return output;
}
@end
