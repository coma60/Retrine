#import "TargetAdmission.h"
#import "NativeAdmission.h"
#include <dlfcn.h>
#include <stdatomic.h>

enum { SAPMainImage=1, SAPSharedImage=2, SAPRequiredImages=SAPMainImage|SAPSharedImage };
static atomic_uint admittedImages;

static unsigned profileImageKind(const struct mach_header *header) {
    Dl_info info;
    if(!dladdr(header,&info)||!info.dli_fname)return 0;
    const char *name=strrchr(info.dli_fname,'/');
    name=name?name+1:info.dli_fname;
    if(!strcmp(name,"Spotify")&&header==_dyld_get_image_header(0))return SAPMainImage;
    if(!strcmp(name,"SpotifyShared"))return SAPSharedImage;
    return 0;
}

static void profileImageAdded(const struct mach_header *header,intptr_t slide) {
    unsigned kind=profileImageKind(header);
    if(!kind)return;
    const uint8_t *uuid=kind==SAPMainImage?SAPProfileMainUUID:SAPProfileSharedUUID;
    if(SAPProfileUUIDMatches((const void *)header,uuid))
        atomic_fetch_or_explicit(&admittedImages,kind,memory_order_release);
}

static void profileImageRemoved(const struct mach_header *header,intptr_t slide) {
    atomic_fetch_and_explicit(&admittedImages,~profileImageKind(header),memory_order_release);
}

// Dyld owns image lifetimes during callbacks; readers never walk an unloadable
// header or an indexed image list. Registration replays already-loaded images.
__attribute__((constructor)) static void observeProfileImages(void) {
    _dyld_register_func_for_remove_image(profileImageRemoved);
    _dyld_register_func_for_add_image(profileImageAdded);
}

bool SAPRuntimeProfileAdmitted(void) {
    return SAPProfileMetadataMatches()&&
        atomic_load_explicit(&admittedImages,memory_order_acquire)==SAPRequiredImages;
}
