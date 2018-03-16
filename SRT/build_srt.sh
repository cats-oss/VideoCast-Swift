#!/bin/sh

#  build_srt.sh
#  VideoCast
#
#  Created by Tomohiro Matsuzawa on 2018/03/13.
#  Copyright © 2018年 CyberAgent, Inc. All rights reserved.

export IPHONEOS_DEPLOYMENT_TARGET=10.0
SDKVERSION=11.2

build_srt() {
    PLATFORM=$1
    IOS_PLATFORM=$2
    ARCH=$3
    IOS_OPENSSL=$(pwd)/openssl/bin/${PLATFORM}${SDKVERSION}-${ARCH}.sdk

    mkdir -p ./build/ios_${ARCH}
    pushd ./build/ios_${ARCH}

../../srt/configure --cmake-prefix-path=$IOS_OPENSSL --cmake-toolchain-file=scripts/iOS.cmake --enable-debug=0 --ios-platform=${IOS_PLATFORM} --ios-arch=${ARCH}
    make
    popd
}

pushd srt
git checkout dev
popd

build_srt iPhoneSimulator SIMULATOR64 x86_64
build_srt iPhoneSimulator SIMULATOR i386
build_srt iPhoneOS OS armv7
build_srt iPhoneOS OS arm64

cp ./build/ios_arm64/version.h Includes
cp ./srt/srtcore/srt.h Includes
cp ./srt/srtcore/logging_api.h Includes
cp ./srt/srtcore/platform_sys.h Includes
cp ./srt/srtcore/udt.h Includes
cp ./srt/srtcore/srt4udt.h Includes

lipo -output libsrt.a -create ./build/ios_x86_64/libsrt.a ./build/ios_i386/libsrt.a ./build/ios_armv7/libsrt.a ./build/ios_arm64/libsrt.a
