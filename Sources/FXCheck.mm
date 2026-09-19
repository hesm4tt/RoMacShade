#import "FXRuntime.h"
#include <cstdio>
#include <cstdlib>
#include <cerrno>

static NSUInteger dimension(const char *s) {
    char *end=nullptr;errno=0;unsigned long n=strtoul(s,&end,10);
    return errno||!*s||*end||n<1||n>16384?0:n;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc!=2&&argc!=4){fprintf(stderr,"Usage: FXCheck effect.fx [width height]\n");return 2;}
    NSUInteger width=argc==4?dimension(argv[2]):1920,height=argc==4?dimension(argv[3]):1080;
    if(!width||!height){fprintf(stderr,"Dimensions must be integers between 1 and 16384.\n");return 2;}
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSError *error=nil;
    auto effect=[[MSFXEffect alloc] initWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]
        device:device width:width height:height error:&error];
    if(!effect){fprintf(stderr,"FX unsupported or invalid: %s\n",error.localizedDescription.UTF8String);return 1;}
    printf("Compiled FX and Metal pipelines for %lu x %lu on %s\n",(unsigned long)width,(unsigned long)height,device.name.UTF8String);
    printf("Techniques: %s\n",[effect.techniqueNames componentsJoinedByString:@", "].UTF8String);
    for(NSDictionary *u in effect.uniforms)
        printf("%s (%s): %s\n",[u[@"name"] UTF8String],[u[@"type"] UTF8String],[[u[@"values"] description] UTF8String]);
    printf("Compilation passed. Frame execution and host integration have not been checked by this command.\n");
    return 0;
}}
