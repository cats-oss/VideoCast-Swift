//
//  AspectTransform.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class AspectTransform: ITransform {
    public enum AspectMode {
        /*!< An aspect mode which shrinks the incoming video to fit in the supplied boundaries. */
        case fit
        /*!< An aspect mode which scales the video to fill the supplied boundaries and maintain aspect ratio. */
        case fill
    }

    private var scale: GLKVector3 = GLKVector3()

    private weak var output: IOutput?

    private var boundingWidth: Int
    private var boundingHeight: Int
    private var prevWidth: Int = 0
    private var prevHeight: Int = 0
    private var aspectMode: AspectMode

    private var boundingBoxDirty: Bool = true

    /*! Constructor.
     *
     *  \param boundingWidth  The width ouf the bounding box.
     *  \param boundingHeight The height of the bounding box.
     *  \param aspectMode     The aspectMode to use.
     */
    public init(boundingWidth: Int,
                boundingHeight: Int,
                aspectMode: AspectMode) {
        self.boundingWidth = boundingWidth
        self.boundingHeight = boundingHeight
        self.aspectMode = aspectMode
    }

    /*!
     *  Change the size of the target bounding box.
     *
     *  \param boundingWidth  The width ouf the bounding box.
     *  \param boundingHeight The height of the bounding box.
     */
    open func setBoundingSize(boundingWidth: Int, boundingHeight: Int) {
        self.boundingWidth = boundingWidth
        self.boundingHeight = boundingHeight
        boundingBoxDirty = true
    }

    /*!
     *  Change the aspect mode
     *
     *  \param aspectMode The aspectMode to use.
     */
    open func setAspectMode(aspectMode: AspectMode) {
        boundingBoxDirty = true
        self.aspectMode = aspectMode
    }

    /*!
     *  Mark the bounding box as dirty and force a refresh.  This may be useful if the
     *  dimensions of the pixel buffer change.
     */
    open func setBoundingBoxDirty() {
        boundingBoxDirty = true
    }

    /*! ITransform::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*! IOutput::pushBuffer */
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let output = output else { return }
        let pb = data.assumingMemoryBound(to: IPixelBuffer.self).pointee

        pb.lock(true)

        let width = pb.width
        let height = pb.height

        if width != prevWidth || height != prevHeight {
            setBoundingBoxDirty()
            prevHeight = height
            prevWidth = width
        }

        if boundingBoxDirty {

            let width = Float(width)
            let height = Float(height)

            var wfac = Float(boundingWidth) / width
            var hfac = Float(boundingHeight) / height

            let mult = (aspectMode == .fit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac

            wfac = width*mult / Float(boundingWidth)
            hfac = height*mult / Float(boundingHeight)

            scale = GLKVector3Make(wfac, hfac, 1)

            boundingBoxDirty = false
        }

        pb.unlock(true)

        guard let md = metadata as? VideoBufferMetadata, let mat = md.data?.matrix else {
            Logger.debug("unexpected return")
            return
        }

        md.data?.matrix = GLKMatrix4ScaleWithVector3(mat, scale)

        output.pushBuffer(data, size: size, metadata: md)
    }

}
