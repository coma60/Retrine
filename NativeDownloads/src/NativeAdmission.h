#pragma once
#include <stdbool.h>

// A loaded-library entry point is not proof that its host was admitted.
// Lock-free image snapshot published by dyld callbacks; bundle metadata is
// immutable. Rejections are never latched, and image removal revokes admission.
bool SAPRuntimeProfileAdmitted(void);
