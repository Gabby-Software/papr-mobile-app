//
//  PhotoCollectionViewCell.swift
//  Papr
//
//  Created by Joan Disho on 22.04.18.
//  Copyright © 2018 Joan Disho. All rights reserved.
//

import UIKit
import RxSwift
import Action
import Nuke

class PhotoCollectionViewCell: UICollectionViewCell, BindableType {

    // MARK: ViewModel
    var viewModel: PhotoCollectionCellModelType!

    // MARK: IBOutlets
    @IBOutlet var collectionTitle: UILabel!
    @IBOutlet var collectionCoverImageView: UIImageView!
    @IBOutlet var addToCollectionButton: UIButton!
    @IBOutlet var activityIndicator: UIActivityIndicatorView!

    // MARK: Private
    private static let nukeManager = Nuke.Manager.shared
    private var disposeBag = DisposeBag()

    // MARK: Overrides

    override func awakeFromNib() {
        super.awakeFromNib()
        collectionCoverImageView.cornerRadius = 10
        addToCollectionButton.cornerRadius = 10
        addToCollectionButton.isExclusiveTouch = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        collectionCoverImageView.image = #imageLiteral(resourceName: "unsplash-icon-placeholder")
        addToCollectionButton.rx.action = nil

        disposeBag = DisposeBag()
    }

    // MARK: BindableType
    func bindViewModel() {
        let inputs = viewModel.inputs
        let outputs = viewModel.outputs
        let this = PhotoCollectionViewCell.self

        outputs.isPhotoInCollection
            .subscribe { result in
                guard let isPart = result.element else { return }
                self.addToCollectionButton.rx.action = isPart ? inputs.removeAction :
                                                                   inputs.addAction
            }
            .disposed(by: disposeBag)
        
        outputs.coverPhotoURL
            .flatMap { this.nukeManager.loadImage(with: $0).orEmpty }
            .flatMapIgnore { [unowned self] _ in
                Observable.just(self.activityIndicator.stopAnimating())
            }
            .bind(to: collectionCoverImageView.rx.image)
            .disposed(by: disposeBag)

        outputs.collectionName
            .bind(to: collectionTitle.rx.text)
            .disposed(by: disposeBag)

        outputs.isPhotoInCollection
            .map { $0 ? .black : .clear }
            .bind(to: addToCollectionButton.rx.backgroundColor)
            .disposed(by: disposeBag)

        outputs.isPhotoInCollection.map { $0 ? 0.6 : 1.0 }
            .bind(to: addToCollectionButton.rx.alpha)
            .disposed(by: disposeBag)

        outputs.isPhotoInCollection.map { $0 ? #imageLiteral(resourceName: "done-white") : nil }
            .bind(to: addToCollectionButton.rx.image())
            .disposed(by: disposeBag)

    }

}
