//
//  Filter.swift
//  DashCamLink
//
//  Created by 김주희 on 2024/06/24.
//  Copyright © 2024 Thinkware. All rights reserved.
//

import CoreImage

  @objc class Filter: CIFilter {
      
      private let kernel: CIKernel

      override init() {

          let url = Bundle.main.url(forResource: "default", withExtension: "metallib")!
          let data = try! Data(contentsOf: url)
          self.kernel = try! CIKernel(functionName: "grayscale", fromMetalLibraryData: data)

          super.init()
      }

      required init?(coder aDecoder: NSCoder) {

          fatalError("init(coder:) has not been implemented")
      }

      @objc func outputImage(input: CIImage) -> CIImage? {

          return self.kernel.apply(extent: input.extent,
                                   roiCallback:  { i, r in r },
                                   arguments: [input])

      }
  }
