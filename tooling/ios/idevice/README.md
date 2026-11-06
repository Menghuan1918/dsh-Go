# idevice FFI for the self-runner

libidevice_ffi.a and idevice.h come from jkcoxson/idevice (MIT), pinned at 3854a5d, plus the
CoreDevice probe patch from iphone-use-app (AGPL-3.0; this repository is AGPL-3.0 too).
The probe adds screenshot, touch, hardware button and ASCII typing over CoreDevice.

Build once before the first Xcode build (needs rustup and the iOS targets):

    tooling/ios/build-idevice.sh

Outputs (gitignored): app/ios/Idevice/libidevice_ffi.a, app/ios/Idevice/sim/libidevice_ffi.a,
and the generated header. app/ios/Idevice/idevice.h and module.modulemap are kept in the tree so
Xcode can resolve the module even before the library exists; rebuild the header when the pin moves.
