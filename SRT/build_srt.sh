#!/bin/sh

#  build_srt.sh
#  VideoCast
#
#  Created by Tomohiro Matsuzawa on 2018/03/13.
#  Copyright © 2018年 CyberAgent, Inc. All rights reserved.

export IPHONEOS_DEPLOYMENT_TARGET=10.0

pushd srt
git checkout dev
popd

IOS_OPENSSL=$(pwd)/openssl/bin/iPhoneOS11.2-armv7.sdk

mkdir -p ./build/ios_armv7
pushd ./build/ios_armv7

../../srt/configure --cmake-prefix-path=$IOS_OPENSSL --cmake-toolchain-file=scripts/iOS.cmake --enable-debug=0 --ios-arch=armv7
make
popd

IOS_OPENSSL=$(pwd)/openssl/bin/iPhoneOS11.2-arm64.sdk

mkdir -p ./build/ios_arm64
pushd ./build/ios_arm64

../../srt/configure --cmake-prefix-path=$IOS_OPENSSL --cmake-toolchain-file=scripts/iOS.cmake --enable-debug=0 --ios-arch=arm64
make
popd

cp ./build/ios_arm64/version.h Includes
cp ./srt/srtcore/srt.h Includes
cp ./srt/srtcore/logging_api.h Includes
cp ./srt/srtcore/platform_sys.h Includes
cp ./srt/srtcore/udt.h Includes
cp ./srt/srtcore/srt4udt.h Includes

lipo -output libsrt.a -create ./build/ios_armv7/libsrt.a ./build/ios_arm64/libsrt.a
