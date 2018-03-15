# VideoCast-Swift

VideoCast-Swift is a framework for broadcasting live video. It is based on [VideoCore](https://github.com/jgh-/VideoCore-Inactive) C++ library but rewritten in Swift. It currently works with iOS. It is a work in progress and will eventually expand to other platforms such as OS X.

## Architecture Overview

Samples start at the source, are passed through a series of transforms, and end up at the output.

e.g. Source (Camera) -> Transform (Composite) -> Transform (H.264 Encode) -> Transform (RTMP Packetize) -> Output (RTMP)

## Features

 - Streaming protocols
   - RTMP publish
   - SRT
 - Encoders
   - H.264
   - HEVC
   - AAC
 - Multiplexers
   - MPEG-2 TS
   - MP4 for recording
 - Mixers
   - Video
   - Audio
 - Sources
   - Camera
   - Microphone
 
