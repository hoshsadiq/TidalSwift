//
//  Helpers.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 23.05.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation
import Combine

public class Helpers {
	unowned let session: Session
	private let metadata: Metadata
	public let downloadStatus = DownloadStatus()
	public let offline: Offline
	public let download: Download

	public init(session: Session) {
		self.session = session
		self.metadata = Metadata(session: session)
		self.offline = Offline(session: session, downloadStatus: downloadStatus)
		self.download = Download(session: session, metadata: self.metadata, downloadStatus: downloadStatus)
	}
}
