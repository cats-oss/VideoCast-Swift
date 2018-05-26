//
//  BasicVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class BasicVideoFilter: IVideoFilter {
    open var vertexKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
attribute vec2 aPos;
attribute vec2 aCoord;
varying vec2   vCoord;
uniform mat4   uMat;
void main(void) {
    gl_Position = uMat * vec4(aPos,0.,1.);
    vCoord = aCoord;
}
""")
    }
    
    open var pixelKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
precision mediump float;
varying vec2      vCoord;
uniform sampler2D uTex0;
void main(void) {
    gl_FragData[0] = texture2D(uTex0, vCoord);
}
""")
    }
    
    open var filterLanguage: FilterLanguage = .GL_ES2_3
    
    open var program: GLuint = 0
    
    open var matrix = GLKMatrix4Identity
    
    open var dimensions = CGSize.zero
    
    open var initialized = false
    
    open var name: String {
        return ""
    }
    
    private var vao: GLuint = 0
    private var uMatrix: Int32 = 0
    private var bound = false
    
    public init() {
        
    }
    
    deinit {
        glDeleteProgram(program)
        glDeleteVertexArraysOES(1, &vao)
    }
    
    open func initialize() {
        switch filterLanguage {
        case .GL_ES2_3, .GL_2:
            guard let vertexKernel = vertexKernel, let pixelKernel = pixelKernel else {
                Logger.debug("unexpected return")
                break
            }
            
            program = buildProgram(vertex: vertexKernel, fragment: pixelKernel)
            glGenVertexArraysOES(1, &vao)
            glBindVertexArrayOES(vao)
            uMatrix = glGetUniformLocation(program, "uMat")
            let attrpos = glGetAttribLocation(program, "aPos")
            let attrtex = glGetAttribLocation(program, "aCoord")
            let unitex = glGetUniformLocation(program, "uTex0")
            glUniform1i(unitex, 0)
            glEnableVertexAttribArray(GLuint(attrpos))
            glEnableVertexAttribArray(GLuint(attrtex))
            glVertexAttribPointer(GLuint(attrpos), GLint(BUFFER_SIZE_POSITION), GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(BUFFER_STRIDE), BUFFER_OFFSET_POSITION)
            glVertexAttribPointer(GLuint(attrtex), GLint(BUFFER_SIZE_POSITION), GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(BUFFER_STRIDE), BUFFER_OFFSET_TEXTURE)
            initialized = true
        case .GL_3:
            break
        }
    }
    
    open func bind() {
        switch filterLanguage {
        case .GL_ES2_3, .GL_2:
            if !bound {
                if !initialized {
                    initialize()
                }
                glUseProgram(program)
                glBindVertexArrayOES(vao)
            }
            glUniformMatrix4fv(uMatrix, 1, GLboolean(GL_FALSE), matrix.array)
        case .GL_3:
            break
        }
    }
    
    open func unbind() {
        bound = false
    }
}
