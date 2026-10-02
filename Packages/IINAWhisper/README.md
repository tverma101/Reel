# IINAWhisper

This package wraps a static universal XCFramework built from
[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), tag `v1.9.4`, commit
`927cfce34f31707e17f2bff35c349632fb9e2c3a`. The upstream license is included in
[LICENSE](LICENSE).

## Why this is a local static build

The upstream `build-xcframework.sh` currently sets the macOS minimum to 13.3, but IINA supports
macOS 12. This framework is compiled for macOS 12.0 and statically linked, so whisper.cpp does not
add a dynamic framework requirement at launch. Metal BF16 is disabled for the macOS 12 target;
Metal, Accelerate, CoreML, and C++ are linked through the framework module map.

The arm64 and x86_64 slices were built separately to preserve each architecture's CPU backend. The
x86_64 build enables AVX and SSE4.2, while leaving AVX2, F16C, FMA, and BMI2 disabled so it can run
on supported Intel Macs without those later instructions. The arm64 build uses the upstream ARM
backend and Metal. The result is a roughly 10 MiB macOS-only XCFramework.

## Rebuilding

Use the upstream `v1.9.4` checkout with its `ggml` submodule initialized. Configure one build
directory for each architecture with `-G Xcode`, `-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0`, and
`-DGGML_METAL_USE_BF16=OFF`. Use these common options:

```text
-DBUILD_SHARED_LIBS=OFF
-DWHISPER_BUILD_EXAMPLES=OFF
-DWHISPER_BUILD_TESTS=OFF
-DWHISPER_BUILD_SERVER=OFF
-DGGML_METAL=ON
-DGGML_METAL_EMBED_LIBRARY=ON
-DGGML_BLAS_DEFAULT=ON
-DGGML_OPENMP=OFF
-DGGML_NATIVE=OFF
-DGGML_CPU_KLEIDIAI=OFF
-DWHISPER_COREML=ON
-DWHISPER_COREML_ALLOW_FALLBACK=ON
```

Set `-DCMAKE_OSX_ARCHITECTURES=arm64` for the arm64 build. For x86_64, also set
`-DCMAKE_OSX_ARCHITECTURES=x86_64`, `-DGGML_SSE42=ON`, `-DGGML_AVX=ON`, and set
`GGML_AVX2`, `GGML_F16C`, `GGML_FMA`, and `GGML_BMI2` to `OFF`.

Build the `whisper` target in Release for both directories. For each architecture, combine
`libwhisper.a`, `libggml.a`, `libggml-base.a`, `libggml-cpu.a`, `libggml-metal.a`,
`libggml-blas.a`, and `libwhisper.coreml.a` with `libtool -static`. Use `lipo -create` on the two
combined archives, place the result in the macOS framework layout with the upstream headers and
module map, then run `xcodebuild -create-xcframework`. The module map must link CoreML in addition to
the frameworks listed by upstream, because this build includes `libwhisper.coreml.a`.

No Whisper or VAD model is bundled here. IINA downloads the pinned, checksummed model files on demand
and keeps them in its Application Support directory.
