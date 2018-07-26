//
//  PositionTransform.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class PositionTransform: ITransform {

    private var matrix: GLKMatrix4 = GLKMatrix4Identity

    private weak var output: IOutput?

    private var posX: Int
    private var posY: Int
    private var width: Int
    private var height: Int
    private var contextWidth: Int
    private var contextHeight: Int

    private var positionIsDirty: Bool = true

    /*! Constructor.
     *
     *  \param x                The x position of the image in the video context.
     *  \param y                The y position of the image in the video context.
     *  \param width            The width of the image.
     *  \param height           The height of the image.
     *  \param contextWidth     The width of the video context.
     *  \param contextHeight    The height of the video context.
     */
    public init(x: Int,
                y: Int,
                width: Int,
                height: Int,
                contextWidth: Int,
                contextHeight: Int) {
        posX = x
        posY = y
        self.width = width
        self.height = height
        self.contextWidth = contextWidth
        self.contextHeight = contextHeight
    }

    /*!
     *  Change the position of the image in the video context.
     *
     *  \param x  The x position of the image in the video context.
     *  \param y  The y position of the image in the video context.
     */
    open func setPosition(x: Int, y: Int) {
        posX = x
        posY = y
        positionIsDirty = true
    }

    /*!
     *  Change the size of the image in the video context.
     *
     *  \param width            The width of the image.
     *  \param height           The height of the image.
     */
    open func setSize(width: Int, height: Int) {
        self.width = width
        self.height = height
        positionIsDirty = true
    }

    /*! ITransform::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*! IOutput::pushBuffer */
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let output = output else {
            Logger.debug("unexpected return")
            return
        }

        if positionIsDirty {
            var mat = GLKMatrix4Identity
            let x = Float(posX), y = Float(posY), cw = Float(contextWidth), ch = Float(contextHeight), w = Float(width), h = Float(height)

            mat = GLKMatrix4TranslateWithVector3(mat,
                                                 GLKVector3Make((x / cw) * 2 - 1,   // The compositor uses homogeneous coordinates.
                                                                (y / ch) * 2 - 1,   // i.e. [ -1 .. 1 ]
                                                                0))

            mat = GLKMatrix4ScaleWithVector3(mat,
                                             GLKVector3Make(w / cw, //
                                                            h / ch, // size is a percentage for scaling.
                                                            1))

            matrix = mat

            positionIsDirty = false
        }
        guard let md = metadata as? VideoBufferMetadata, let mat = md.data?.matrix else {
            Logger.debug("unexpected return")
            return
        }

        md.data?.matrix = GLKMatrix4Multiply(mat, matrix)

        output.pushBuffer(data, size: size, metadata: md)
    }

}
