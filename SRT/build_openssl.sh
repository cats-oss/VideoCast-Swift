#!/bin/sh

#  build_openssl.sh
#  VideoCast
#
#  Created by Tomohiro Matsuzawa on 2018/03/13.
#  Copyright © 2018年 CyberAgent, Inc. All rights reserved.

pushd ./openssl

./build-libssl.sh --archs="x86_64 i386 armv7 arm64"

popd

cp ./openssl/lib/libcrypto.a .
