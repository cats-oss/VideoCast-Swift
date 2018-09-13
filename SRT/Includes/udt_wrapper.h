//
//  udt_wrapper.h
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/07.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

#ifndef udt_wrapper_hpp
#define udt_wrapper_hpp

#include "srt.h"

#ifdef __cplusplus
extern "C" {
#endif
    
typedef struct {
    int code;
    const char* message;
    char buf[1024];
} UdtErrorInfo;

UdtErrorInfo udtGetLastError();
int udtSetStreamId(SRTSOCKET u, const char* sid);
const char* udtGetStreamId(SRTSOCKET u);
int udtSetLogStream(const char* logfile);

#ifdef __cplusplus
}
#endif

#endif /* udt_wrapper_hpp */
