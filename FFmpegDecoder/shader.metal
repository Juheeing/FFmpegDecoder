//
//  shader.metal
//  DashCamLink
//
//  Created by 김주희 on 2024/06/21.
//  Copyright © 2024 Thinkware. All rights reserved.
//

#include <metal_stdlib>

using namespace metal;

#include <CoreImage/CoreImage.h>

extern "C" {
    namespace coreimage {
        half4 grayscale(sample_h s) {

            half y = 0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b;

            return half4(y, y, y, s.a);
        }
    }
}
