#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// A raster ReShade FX effect compiled for a particular device and frame size.
/// Loading compiles source and Metal pipelines synchronously. Keep instances for reuse.
@interface MSFXEffect : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url
                             device:(id<MTLDevice>)device
                              width:(NSUInteger)width
                              height:(NSUInteger)height
                              error:(NSError * _Nullable * _Nullable)error;
/// Definitions override compiler compatibility defaults. Include directories
/// supplement the effect file's own directory and must be local file URLs.
- (nullable instancetype)initWithURL:(NSURL *)url
                             device:(id<MTLDevice>)device
                              width:(NSUInteger)width
                             height:(NSUInteger)height
                        definitions:(NSDictionary<NSString *, NSString *> *)definitions
                 includeDirectories:(NSArray<NSURL *> *)includeDirectories
                              error:(NSError * _Nullable * _Nullable)error;
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) NSArray<NSString *> *techniqueNames;
@property(nonatomic, readonly) NSString *activeTechnique;
/// YES when the currently selected technique samples a DEPTH-semantic texture.
/// Unused depth declarations and other techniques do not require a depth input.
@property(nonatomic, readonly) BOOL requiresDepth;
/// Immutable dictionaries with name, type, components, values, source and
/// defaultValues (NSNumber arrays). uiLabel/uiTooltip/uiType are strings;
/// uiItems is an array of strings from the NUL-separated ReShade annotation.
/// Optional uiMin/uiMax/uiStep are NSNumber for scalar annotations and arrays
/// of NSNumber for vector annotations. Defaults remain fixed after editing.
@property(nonatomic, readonly) NSArray<NSDictionary *> *uniforms;
- (BOOL)selectTechniqueNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setUniformNamed:(NSString *)name values:(NSArray<NSNumber *> *)values
                 error:(NSError * _Nullable * _Nullable)error;
/// Shares named FX textures between technique instances compiled from the same
/// file/device/dimensions/definitions/include paths. Call before this instance
/// starts encoding. Encode related techniques into the same command buffer, in
/// preset order, to exchange intermediate targets (for example LightDoF focus).
/// Overlapping command buffers own separate writable textures; temporal inputs
/// come from the most recently completed successful frame.
- (BOOL)shareResourcesWithEffect:(MSFXEffect *)effect
                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    texture:(id<MTLTexture>)texture
                       time:(double)seconds
                      error:(NSError * _Nullable * _Nullable)error;
/// Appends the selected technique using the caller's depth input for DEPTH
/// samplers. Required input is a readable, stored, single-sample R32Float 2D
/// texture on the same device; its dimensions may differ from the color frame.
/// Supply normalized, non-reversed 0...1 camera depth in top-left UV orientation.
/// FX depth macros may deliberately override that convention. The caller must
/// finish writing depth before encoding and avoid overwriting it until completion.
/// The runtime retains the supplied texture through command-buffer completion.
/// Passing nil fails before encoding when requiresDepth is YES; otherwise ignored.
- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    texture:(id<MTLTexture>)texture
               depthTexture:(nullable id<MTLTexture>)depthTexture
                       time:(double)seconds
                      error:(NSError * _Nullable * _Nullable)error;
@end

/// Installs/replaces the effect used by the process-local Metal hooks.
/// Passing nil removes the FX effect. Built-in color settings remain independent.
FOUNDATION_EXPORT void MSSetFXEffect(MSFXEffect * _Nullable effect);
FOUNDATION_EXPORT MSFXEffect * _Nullable MSGetFXEffect(void);
/// Replaces the active effects in execution order. The host omits disabled
/// effects. The array is copied; its effect objects remain independently editable.
FOUNDATION_EXPORT void MSSetFXEffects(NSArray<MSFXEffect *> *effects);
/// Returns an immutable, ordered snapshot, or an empty array when none are installed.
FOUNDATION_EXPORT NSArray<MSFXEffect *> *MSGetFXEffects(void);
/// Counts processed drawable frames once when every effect in a nonempty chain
/// successfully encodes. It does not count individual effects or GPU completion.
FOUNDATION_EXPORT uint64_t MSProcessedFXFrameCount(void);
NS_ASSUME_NONNULL_END
