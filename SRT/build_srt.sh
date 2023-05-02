#!/bin/sh

#  build_srt.sh
#  VideoCast
#
#  Created by Tomohiro Matsuzawa on 2018/03/13.
#  Copyright © 2018年 CyberAgent, Inc. All rights reserved.

export IPHONEOS_DEPLOYMENT_TARGET=8.0
SDKVERSION=16.1

build_srt() {
    PLATFORM=$1
    IOS_PLATFORM=$2
    ARCH=$3
    IOS_OPENSSL=$(pwd)/openssl/bin/${PLATFORM}${SDKVERSION}-${ARCH}.sdk
    
    mkdir -p ./build/ios_${IOS_PLATFORM}_${ARCH}
    pushd ./build/ios_${IOS_PLATFORM}_${ARCH}

    cp $IOS_OPENSSL/lib/libcrypto.a .

../../srt/configure --cmake-prefix-path=$IOS_OPENSSL --use-openssl-pc=OFF --cmake-toolchain-file=scripts/iOS.cmake --enable-debug=0 --ios-platform=${IOS_PLATFORM} --ios-arch=${ARCH}
    make
    popd
}
# clear out the cmake build cache
rm -rf build
rm -rf libsrt.xcframework
rm -rf libcrypto.xcframework

build_srt iPhoneSimulator SIMULATOR64 x86_64
build_srt iPhoneSimulator SIMULATOR64 arm64
build_srt iPhoneOS OS arm64

cp ./build/ios_OS_arm64/version.h Includes
cp ./srt/srtcore/srt.h Includes
cp ./srt/srtcore/logging_api.h Includes
cp ./srt/srtcore/platform_sys.h Includes
cp ./srt/srtcore/udt.h Includes
cp ./srt/srtcore/srt4udt.h Includes

lipo -output libsrt.a -create ./build/ios_SIMULATOR64_x86_64/libsrt.a ./build/ios_SIMULATOR64_arm64/libsrt.a 
xcodebuild -create-xcframework -library libsrt.a -library ./build/ios_OS_arm64/libsrt.a -output libsrt.xcframework

lipo -output libcrypto.a -create ./build/ios_SIMULATOR64_x86_64/libcrypto.a ./build/ios_SIMULATOR64_arm64/libcrypto.a
xcodebuild -create-xcframework -library libcrypto.a -library ./build/ios_OS_arm64/libcrypto.a -output libcrypto.xcframework

# clear out the cache of libsrt.a and libcrypto.a
rm libsrt.a
rm libcrypto.a