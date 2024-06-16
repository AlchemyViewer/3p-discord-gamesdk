#!/usr/bin/env bash

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about undefined vars
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(dirname "$0")"
STAGING_DIR="$(pwd)"

# load autbuild provided shell functions and variables
source_environment_tempfile="$STAGING_DIR/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

DISCORD_SOURCE_DIR=discord_game_sdk
DISCORD_VERSION="3.2.1"

echo "${DISCORD_VERSION}" > "${STAGING_DIR}/VERSION.txt"

# Create staging dirs
mkdir -p "$STAGING_DIR/include/discord"
mkdir -p "$STAGING_DIR/lib/debug"
mkdir -p "$STAGING_DIR/lib/release"

pushd "$top/$DISCORD_SOURCE_DIR/cpp"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            mkdir -p "build_release"
            pushd "build_release"
                # Invoke cmake and use as official build
                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" .. \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $STAGING_DIR)/release"

                cmake --build . --config Release --clean-first
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cp -a Release/*.lib $STAGING_DIR/lib/release/
            popd

            # copy libs
            cp -a ../lib/x86_64/*.lib $STAGING_DIR/lib/release/
            cp -a ../lib/x86_64/*.dll $STAGING_DIR/lib/release/

            # copy headers
            cp -a *.h $STAGING_DIR/include/discord/
        ;;
        darwin*)
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -G Ninja \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$STAGING_DIR/release_x86"

                cmake --build . --config Release

            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -G Ninja \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$STAGING_DIR/release_arm64"

                cmake --build . --config Release

            popd

            # create fat libraries
            lipo -create build_release_x86/libdiscordgamesdk.a build_release_arm64/libdiscordgamesdk.a -output ${STAGING_DIR}/lib/release/libdiscordgamesdk.a
            cp -a ../lib/x86_64/*.dylib $STAGING_DIR/lib/release/
            pushd $STAGING_DIR/lib/release/
                install_name_tool -id "@rpath/discord_game_sdk.dylib" "discord_game_sdk.dylib"
            popd

            if [ -n "${APPLE_SIGNATURE:=""}" -a -n "${APPLE_KEY:=""}" -a -n "${APPLE_KEYCHAIN:=""}" ]; then
                KEYCHAIN_PATH="$HOME/Library/Keychains/$APPLE_KEYCHAIN"
                security unlock-keychain -p $APPLE_KEY $KEYCHAIN_PATH
                for dylib in $STAGING_DIR/lib/*/discord_game_sdk*.dylib;
                do
                    if [ -f "$dylib" ]; then
                        codesign --keychain "$KEYCHAIN_PATH" --sign "$APPLE_SIGNATURE" --force --timestamp "$dylib" || true
                    fi
                done
                security lock-keychain $KEYCHAIN_PATH
            else
                echo "Code signing not configured; skipping codesign."
            fi

            # copy headers
            cp -a *.h $STAGING_DIR/include/discord/
        ;;
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"   

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts_c" \
                cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_CXX_STANDARD="17" \
                    -DCMAKE_C_FLAGS="$opts_c" \
                    -DCMAKE_CXX_FLAGS="$opts_cxx" \
                    -DCMAKE_INSTALL_PREFIX="$STAGING_DIR/release"

                cmake --build . --config Release

                cp -a libdiscordgamesdk.a $STAGING_DIR/lib/release/
            popd

            # copy libs
            cp -a ../lib/x86_64/discord_game_sdk.so $STAGING_DIR/lib/release/libdiscord_game_sdk.so

            # copy headers
            cp -a *.h $STAGING_DIR/include/discord/
        ;;
    esac

    mkdir -p "$STAGING_DIR/LICENSES"
   touch "$STAGING_DIR/LICENSES/discord-gamesdk.txt"
popd
