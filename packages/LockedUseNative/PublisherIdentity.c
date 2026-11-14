#include "LockedUseNative.h"

#ifndef OCU_PUBLISHER_BUNDLE_ID
#define OCU_PUBLISHER_BUNDLE_ID "com.example.ultraterm-computer-use"
#endif

const char *ocu_publisher_bundle_identifier(void) {
    return OCU_PUBLISHER_BUNDLE_ID;
}
