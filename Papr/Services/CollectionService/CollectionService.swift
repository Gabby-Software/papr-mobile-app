//
//  CollectionService.swift
//  Papr
//
//  Created by Joan Disho on 22.04.18.
//  Copyright © 2018 Joan Disho. All rights reserved.
//

import Foundation
import RxSwift
import Moya

struct CollectionService: CollectionServiceType {

    private var unsplash: MoyaProvider<Unsplash>

    init(unsplash: MoyaProvider<Unsplash> = MoyaProvider<Unsplash>()) {
        self.unsplash = unsplash
    }

    func myCollections() -> Observable<[PhotoCollection]> {
        return unsplash.rx.request(.getMe)
            .map(User.self)
            .map { $0.username }
            .asObservable()
            .unwrap()
            .flatMap { username in
                self.unsplash.rx.request(.userCollections(
                    username: username,
                    page: 1,
                    perPage: 10)
                )
                .map([PhotoCollection].self)
            }
    }

    func photos(fromCollectionId id: Int) -> Observable<[Photo]> {
        return unsplash.rx.request(.collectionPhotos(id: id, page: 1, perPage: 10))
            .map([Photo].self)
            .asObservable()
    }

    func addPhotoToCollection(withCollectionId id: Int, photoId: String) -> Observable<Void> {
        return unsplash.rx.request(.addPhotoToCollection(collectionID: id, photoID: photoId))
            .asObservable()
            .ignoreAll()
    }

    
}

