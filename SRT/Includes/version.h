/*****************************************************************************
 * SRT - Secure, Reliable, Transport
 * Copyright (c) 2017 Haivision Systems Inc.
 * 
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 * 
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; If not, see <http://www.gnu.org/licenses/>
 * 
 *****************************************************************************/

/*****************************************************************************
written by
   Haivision Systems Inc.
 *****************************************************************************/

#ifndef INC__SRT_VERSION_H
#define INC__SRT_VERSION_H

// To construct version value
#define SRT_MAKE_VERSION(major, minor, patch) \
   ((patch) + ((minor)*0x100) + ((major)*0x10000))
#define SRT_MAKE_VERSION_VALUE SRT_MAKE_VERSION

#define SRT_VERSION_MAJOR 1
#define SRT_VERSION_MINOR 3
#define SRT_VERSION_PATCH 0

#define SRT_VERSION_STRING "1.3.0"
#define SRT_VERSION_VALUE \
   SRT_MAKE_VERSION_VALUE( \
      SRT_VERSION_MAJOR, SRT_VERSION_MINOR, SRT_VERSION_PATCH )

#endif // INC__SRT_VERSION_H
