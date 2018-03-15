//
//  GLESUtil.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/23.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import OpenGLES

func BUFFER_OFFSET(_ n: Int) -> UnsafeRawPointer? {
    return UnsafeRawPointer(bitPattern: n)
}
let BUFFER_OFFSET_POSITION = BUFFER_OFFSET(0)
let BUFFER_OFFSET_TEXTURE = BUFFER_OFFSET(8)

let BUFFER_SIZE_POSITION = 2
let BUFFER_SIZE_TEXTURE = 2
let BUFFER_STRIDE = MemoryLayout<Float>.size * 4

#if DEBUG
    func glErrors(file: String = #file, line: Int = #line) {
        var glerr: GLenum
        repeat {
            glerr = glGetError()
            guard glerr != GLenum(GL_NO_ERROR) else { break }
            switch glerr {
            case GLenum(GL_INVALID_ENUM):
                Logger.error("OGL( \(file) ):: \(line): Invalid Enum")
            case GLenum(GL_INVALID_VALUE):
                Logger.error("OGL( \(file) ):: \(line): Invalid Value")
            case GLenum(GL_INVALID_OPERATION):
                Logger.error("OGL( \(file) ):: \(line): Invalid Operation")
            case GLenum(GL_OUT_OF_MEMORY):
                Logger.error("OGL( \(file) ):: \(line): Out of Memory")
            default:
                break
            }
        } while ( true )
    }
    
    func glFramebufferStatus(file: String = #file, line: Int = #line) {
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        switch status {
        case GLenum(GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT):
            Logger.error("OGL( \(file) ):: \(line): Incomplete attachment")
        case GLenum(GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS):
            Logger.error("OGL( \(file) ):: \(line): Incomplete dimensions")
        case GLenum(GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT):
            Logger.error("OGL( \(file) ):: \(line): Incomplete missing attachment")
        case GLenum(GL_FRAMEBUFFER_UNSUPPORTED):
            Logger.error("OGL( \(file) ):: \(line): Framebuffer combination unsupported")
        default:
            break
        }
    }
#else
    func glErrors(file: String = #file, line: Int = #line) {
        
    }
    
    func glFramebufferStatus(file: String = #file, line: Int = #line) {
        
    }
#endif

let s_vbo: [GLfloat] = [
    -1, -1,       0, 0, // 0
    1, -1,        1, 0, // 1
    -1, 1,        0, 1, // 2
    
    1, -1,        1, 0, // 1
    1, 1,         1, 1, // 3
    -1, 1,        0, 1  // 2
]

let s_vs = """
attribute vec2 aPos;
attribute vec2 aCoord;
varying vec2 vCoord;
void main(void) {
gl_Position = vec4(aPos,0.,1.);
vCoord = aCoord;
}
"""

let s_vs_mat = """
attribute vec2 aPos;
attribute vec2 aCoord;
varying vec2 vCoord;
uniform mat4 uMat;
void main(void) {
gl_Position = uMat * vec4(aPos,0.,1.);
vCoord = aCoord;
}
"""

let s_fs = """
precision mediump float;
varying vec2 vCoord;
uniform sampler2D uTex0;
void main(void) {
gl_FragData[0] = texture2D(uTex0, vCoord);
}
"""

func compileShader(type: GLuint, source: String) -> GLuint {
    let shaderString = NSString(string: source)
    var shaderCString = shaderString.utf8String
    
    let shader = glCreateShader(type)
    glShaderSource(shader, 1, &shaderCString, nil)
    glCompileShader(shader)
    var compiled: GLint = 0
    glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
#if DEBUG
    if compiled == 0 {
        var length: GLint = 0
        var log: [GLchar]
        
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &length)
        log = Array(repeating: GLchar(0), count: Int(length))

        glGetShaderInfoLog(shader, length, &length, UnsafeMutablePointer(mutating: log))
        Logger.error("\(type == GL_VERTEX_SHADER ? "GL_VERTEX_SHADER" : "GL_FRAGMENT_SHADER") compilation error: \(log)")
        
        return 0
    }
#endif
    return shader
}

func buildProgram(vertex: String, fragment: String) -> GLuint {
    let vshad: GLuint
    let fshad: GLuint
    let p: GLuint
    
    var len: GLint = 0
#if DEBUG
    var log: [GLchar]
#endif
    
    vshad = compileShader(type: GLuint(GL_VERTEX_SHADER), source: vertex)
    fshad = compileShader(type: GLuint(GL_FRAGMENT_SHADER), source: fragment)
    
    p = glCreateProgram()
    glAttachShader(p, vshad)
    glAttachShader(p, fshad)
    glLinkProgram(p)
    glGetProgramiv(p, GLenum(GL_INFO_LOG_LENGTH), &len)
    
#if DEBUG
    if len > 0 {
        log = Array(repeating: GLchar(0), count: Int(len))
        
        glGetProgramInfoLog(p, len, &len, UnsafeMutablePointer(mutating: log))
        
        Logger.debug("program log: \(log)")
    }
#endif
    
    glDeleteShader(vshad)
    glDeleteShader(fshad)
    return p
}
