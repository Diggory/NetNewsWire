//
//  PreloadedWebView.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 2/25/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation
import WebKit

class PreloadedWebView: WKWebView {
	
	private var isReady: Bool = false
	private var readyCompletion: (() -> Void)?
	
	init(articleIconSchemeHandler: ArticleIconSchemeHandler) {
		let preferences = WKPreferences()
		preferences.javaScriptCanOpenWindowsAutomatically = false
		
		/// The defaults for `preferredContentMode` and `allowsContentJavaScript` are suitable
		/// and don't need to be explicitly set.
		/// `allowsContentJavaScript` replaces `WKPreferences.javascriptEnabled`.
		let webpagePreferences = WKWebpagePreferences()

		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences = webpagePreferences
		configuration.preferences = preferences
		configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
		configuration.allowsInlineMediaPlayback = true
		configuration.mediaTypesRequiringUserActionForPlayback = .audio
		if #available(iOS 15.4, *) {
			configuration.preferences.isElementFullscreenEnabled = true
		}
		configuration.setURLSchemeHandler(articleIconSchemeHandler, forURLScheme: ArticleRenderer.imageIconScheme)
		
		super.init(frame: .zero, configuration: configuration)
	}
	
	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	func preload() {
		navigationDelegate = self
		loadFileURL(ArticleRenderer.blank.url, allowingReadAccessTo: ArticleRenderer.blank.baseURL)
	}
	
	func ready(completion: @escaping () -> Void) {
		if isReady {
			completeRequest(completion: completion)
		} else {
			readyCompletion = completion
		}
	}
	
}

// MARK: WKScriptMessageHandler

extension PreloadedWebView: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		isReady = true
		if let completion = readyCompletion {
			completeRequest(completion: completion)
			readyCompletion = nil
		}
	}
		
}

// MARK: Private

private extension PreloadedWebView {
	
	func completeRequest(completion: @escaping () -> Void) {
		isReady = false
		navigationDelegate = nil
		completion()
	}
	
}
