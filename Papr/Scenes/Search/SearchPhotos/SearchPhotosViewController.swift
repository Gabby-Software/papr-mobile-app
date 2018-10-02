//
//  SearchPhotosViewController.swift
//  Papr
//
//  Created by Joan Disho on 26.05.18.
//  Copyright © 2018 Joan Disho. All rights reserved.
//

import UIKit
import RxSwift
import RxCocoa
import RxDataSources

class SearchPhotosViewController: UIViewController, BindableType {

    typealias SearchPhotosSectionModel = SectionModel<String, SearchPhotosCellModelType>

    // MARK: ViewModel
    var viewModel: SearchPhotosViewModelType!

    // MARK: IBOutlets
    @IBOutlet var collectionView: UICollectionView!

    // MARK: Privates
    private var loadingView: LoadingView!
    private var dataSource: RxCollectionViewSectionedReloadDataSource<SearchPhotosSectionModel>!
    private let disposeBag = DisposeBag()

    override func viewDidLoad() {
        super.viewDidLoad()

        configureCollectionView()
        configureLoadingView()
    }

    func bindViewModel() {
        let inputs = viewModel.inputs
        let outputs = viewModel.outputs

        outputs.navTitle
            .bind(to: rx.title)
            .disposed(by: disposeBag)

        outputs.searchPhotosCellModelType
            .map { [SearchPhotosSectionModel(model: "", items: $0)] }
            .flatMapIgnore { [unowned self] _ in
                Observable.just(self.loadingView.stopAnimating())
            }
            .bind(to: collectionView.rx.items(dataSource: dataSource))
            .disposed(by: disposeBag)

        collectionView.rx.reachedBottom()
            .bind(to: inputs.loadMore)
            .disposed(by: disposeBag)
    }

    // MARK: UI
    private func configureLoadingView() {
        loadingView = LoadingView(frame: collectionView.frame)
        loadingView.add(to: view).pinToEdges()
    }

    private func configureCollectionView() {
        guard let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }

        let spacing = 2 / UIScreen.main.scale
        let cellWidth = (UIScreen.main.bounds.width / 3) - spacing

        flowLayout.itemSize = CGSize(width: cellWidth, height: cellWidth)
        flowLayout.minimumInteritemSpacing = spacing
        flowLayout.minimumLineSpacing = spacing

        collectionView.register(cellType: SearchPhotosCell.self)

        dataSource = RxCollectionViewSectionedReloadDataSource<SearchPhotosSectionModel>(
            configureCell:  collectionViewDataSource
        )
    }

    private var collectionViewDataSource: CollectionViewSectionedDataSource<SearchPhotosSectionModel>.ConfigureCell {
        return { _, collectionView, indexPath, cellModel in
            var cell = collectionView.dequeueReusableCell(withCellType: SearchPhotosCell.self, forIndexPath: indexPath)
            cell.bind(to: cellModel)
            return cell
        }
    }
}


