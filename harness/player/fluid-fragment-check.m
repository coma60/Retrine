// Ask Metal which cover textures each compiled copy pass actually reads. No pixel baseline.
#import <Metal/Metal.h>
#import "../harness-fail.h"
#include "shader.inc"

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:kShader options:nil error:&error];
        if (!library) HARNESS_FAIL(@"shader compilation: %@", error);
        for (NSString *name in @[@"copyFragment", @"fadeFragment"]) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:@"copyVertex"];
            d.fragmentFunction = [library newFunctionWithName:name];
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
            MTLRenderPipelineReflection *reflection;
            if (![device newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionBindingInfo reflection:&reflection error:&error])
                HARNESS_FAIL(@"pipeline %@: %@", name, error);
            NSMutableIndexSet *textures = [NSMutableIndexSet indexSet];
            for (id<MTLBinding> binding in reflection.fragmentBindings)
                if (binding.type == MTLBindingTypeTexture && binding.used) [textures addIndex:binding.index];
            NSIndexSet *expected = [name isEqual:@"copyFragment"] ? [NSIndexSet indexSetWithIndex:1] :
                [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)];
            if (![textures isEqual:expected]) HARNESS_FAIL(@"%@ reads cover slots %@", name, textures);
        }
        MTLRenderPipelineDescriptor *show = [MTLRenderPipelineDescriptor new];
        show.vertexFunction = [library newFunctionWithName:@"showVertex"];
        show.fragmentFunction = [library newFunctionWithName:@"showFragment"];
        show.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLRenderPipelineReflection *showRefl;
        if (![device newRenderPipelineStateWithDescriptor:show options:MTLPipelineOptionBindingInfo reflection:&showRefl error:&error])
            HARNESS_FAIL(@"pipeline show: %@", error);
        NSUInteger showUniformSize = 0;
        for (id<MTLBinding> binding in showRefl.fragmentBindings) {
            if (binding.type == MTLBindingTypeBuffer && binding.index == 0)
                showUniformSize = ((id<MTLBufferBinding>)binding).bufferDataSize;
        }
        if (showUniformSize != 64) HARNESS_FAIL(@"ShowU buffer size %lu, expected 64", (unsigned long)showUniformSize);
        puts("PASS: settled pass reads only the destination; fade reads both; show pipeline links with 64-byte ShowU");
    }
    return 0;
}
