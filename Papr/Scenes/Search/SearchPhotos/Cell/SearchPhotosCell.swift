//
//  SearchPhotosCell.swift
//  Papr
//
//  Created by Joan Disho on 27.05.18.
//  Copyright © 2018 Joan Disho. All rights reserved.
//

import UIKit
import RxSwift
import Nuke

class SearchPhotosCell: UICollectionViewCell, BindableType, NibIdentifiable & ClassIdentifiable {

    // MARK: ViewModel
    var viewModel: SearchPhotosCellModelType!

    // MARK: IBOutlets
    @IBOutlet var photoImageView: UIImageView!
    @IBOutlet var activityIndicator: UIActivityIndicatorView!

    // MARK: Privates
    private static let imagePipeline = Nuke.ImagePipeline.shared
    private var disposeBag = DisposeBag()

    override func prepareForReuse() {
        super.prepareForReuse()

        photoImageView.image = nil
        disposeBag = DisposeBag()
    }

    func bindViewModel() {
        let outputs = viewModel.outputs
        let this = SearchPhotosCell.self

        outputs.photo
            .map { $0.id }
            .unwrap()
            .bind(to: photoImageView.rx.heroId)
            .disposed(by: disposeBag)

       let smallPhotoURL = outputs.photo
            .map { $0.urls?.small }
            .unwrap()

        let regularPhotoURL = outputs.photo
            .map { $0.urls?.regular }
            .unwrap()

        Observable.combineLatest(smallPhotoURL, regularPhotoURL)
            .flatMap { small, regular -> Observable<ImageResponse> in
                return Observable.concat(
                    this.imagePipeline.rx.loadImage(with: URL(string: small)!).asObservable(),
                    this.imagePipeline.rx.loadImage(with: URL(string: regular)!).asObservable()
                )
            }
            .orEmpty()
            .map { $0.image }
            .execute { [unowned self] _ in
                self.activityIndicator.stopAnimating()
            }
            .bind(to: photoImageView.rx.image)
            .disposed(by: disposeBag)
    }
}
