//
//  udt_wrapper.cpp
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/07.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

#include "udt_wrapper.h"
#include "udt.h"

extern "C" {
    UdtErrorInfo udtGetLastError() {
        UdtErrorInfo errorInfo;
        
        UDT::ERRORINFO udtError = UDT::getlasterror();
        
        errorInfo.code = udtError.getErrorCode();
        strcpy(errorInfo.buf, udtError.getErrorMessage());
        errorInfo.message = &errorInfo.buf[0];

        udtError.clear();
        
        return errorInfo;
    }
    
    int udtSetStreamId(SRTSOCKET u, const char* sid) {
        return UDT::setstreamid(u, sid);
    }
    
    const char* udtGetStreamId(SRTSOCKET u) {
        return UDT::getstreamid(u).c_str();
    }
    
    int udtSetLogStream(const char* logfile) {
        std::ofstream logfile_stream;
        logfile_stream.open(logfile);
        if ( !logfile_stream )
        {
            return SRT_ERROR;
        }
        else
        {
            UDT::setlogstream(logfile_stream);
        }
        
        return 0;
    }
}
