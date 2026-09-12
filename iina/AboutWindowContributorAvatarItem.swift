//
//  AboutWindowContributorAvatarItem.swift
//  iina
//
//  Created by Collider LI on 4/11/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import Just
import SwiftUI

private final class AboutWindowContributorAvatarLoader: ObservableObject {
  static let imageCache = NSCache<NSString, NSImage>()

  @Published private(set) var image: NSImage?

  init(avatarURL: String) {
    if let cachedImage = Self.imageCache.object(forKey: avatarURL as NSString) {
      image = cachedImage
      return
    }

    Just.get(avatarURL, asyncCompletionHandler: { [weak self] response in
      guard let data = response.content, var image = NSImage(data: data) else { return }
      image = image.rounded()
      Self.imageCache.setObject(image, forKey: avatarURL as NSString)
      DispatchQueue.main.async {
        self?.image = image
      }
    })
  }
}

struct AboutWindowContributorAvatarItem: View {
  @StateObject private var loader: AboutWindowContributorAvatarLoader

  init(avatarURL: String) {
    _loader = StateObject(wrappedValue: AboutWindowContributorAvatarLoader(avatarURL: avatarURL))
  }

  var body: some View {
    Group {
      if let image = loader.image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.clear
      }
    }
    .clipShape(Circle())
    .shadow(color: Color(nsColor: .controlBackgroundColor), radius: 2, x: 0, y: -1)
  }
}
