// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageTask

/// A task performed by the `ImagePipeline`. The pipeline maintains a strong
/// reference to the task until the request finishes or fails; you do not need
/// to maintain a reference to the task unless it is useful to do so for your
/// app’s internal bookkeeping purposes.
public /* final */ class ImageTask: Hashable {
    /// An identifier uniquely identifies the task within a given pipeline. Only
    /// unique within this pipeline.
    public let taskId: Int

    /// The request with which the task was created. The request might change
    /// during the exetucion of a task. When you update the priority of the task,
    /// the request's prir also gets updated.
    public private(set) var request: ImageRequest

    /// The number of bytes that the task has received.
    public fileprivate(set) var completedUnitCount: Int64 = 0

    /// A best-guess upper bound on the number of bytes the client expects to send.
    public fileprivate(set) var totalUnitCount: Int64 = 0

    /// Returns a progress object for the task. The object is created lazily.
    public var progress: Progress {
        if _progress == nil { _progress = Progress() }
        return _progress!
    }
    fileprivate private(set) var _progress: Progress?

    /// A completion handler to be called when task finishes or fails.
    public typealias Completion = (_ response: ImageResponse?, _ error: ImagePipeline.Error?) -> Void
    /// A progress handler to be called periodically during the lifetime of a task.
    public typealias ProgressHandler = (_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void

    // internal stuff associated with a task
    fileprivate var metrics: ImageTaskMetrics
    fileprivate var priorityObserver: ((ImageTask, ImageRequest.Priority) -> Void)?
    fileprivate weak var session: ImageLoadingSession?
    fileprivate var cts = _CancellationSource()

    internal init(taskId: Int, request: ImageRequest) {
        self.taskId = taskId
        self.request = request
        self.metrics = ImageTaskMetrics(taskId: taskId, startDate: Date())
    }

    // MARK: - Priority

    /// Update s priority of the task even if the task is already running.
    public func setPriority(_ priority: ImageRequest.Priority) {
        request.priority = priority
        priorityObserver?(self, priority)
    }

    // MARK: - Cancellation

    /// Marks task as being cancelled.
    ///
    /// The pipeline will immediately cancel any work associated with a task
    /// unless there is an equivalent outstanding task running (see
    /// `ImagePipeline.Configuration.isDeduplicationEnabled` for more info).
    public func cancel() {
        cts.cancel()
    }

    // MARK: - Hashable

    public static func == (lhs: ImageTask, rhs: ImageTask) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}

// MARK: - ImageResponse

/// Represents an image response.
public final class ImageResponse {
    public let image: Image
    public let urlResponse: URLResponse?
    // the response is only nil when new disk cache is enabled (it only stores
    // data for now, but this might change in the future).

    public init(image: Image, urlResponse: URLResponse?) {
        self.image = image; self.urlResponse = urlResponse
    }
}

// MARK: - ImagePipeline

/// `ImagePipeline` will load and decode image data, process loaded images and
/// store them in caches.
///
/// See [Nuke's README](https://github.com/kean/Nuke) for a detailed overview of
/// the image pipeline and all of the related classes.
///
/// `ImagePipeline` is created with a configuration (`Configuration`).
///
/// `ImagePipeline` is thread-safe.
public /* final */ class ImagePipeline {
    public let configuration: Configuration

    // This is a queue on which we access the sessions.
    private let queue = DispatchQueue(label: "com.github.kean.Nuke.ImagePipeline")

    // Image loading sessions. One or more tasks can be handled by the same session.
    private var sessions = [AnyHashable: ImageLoadingSession]()

    private var nextTaskId: Int32 = 0
    private var nextSessionId: Int32 = 0

    private let rateLimiter: RateLimiter

    /// Shared image pipeline.
    public static var shared = ImagePipeline()

    /// The closure that gets called each time the task is completed (or cancelled).
    /// Guaranteed to be called on the main thread.
    public var didFinishCollectingMetrics: ((ImageTask, ImageTaskMetrics) -> Void)?

    public struct Configuration {
        /// Image cache used by the pipeline.
        public var imageCache: ImageCaching?

        /// Data loader used by the pipeline.
        public var dataLoader: DataLoading

        /// Data loading queue. Default maximum concurrent task count is 6.
        public var dataLoadingQueue = OperationQueue()

        /// Default implementation uses shared `ImageDecoderRegistry` to create
        /// a decoder that matches the context.
        internal var imageDecoder: (ImageDecodingContext) -> ImageDecoding = {
            return ImageDecoderRegistry.shared.decoder(for: $0)
        }

        /// Image decoding queue. Default maximum concurrent task count is 1.
        public var imageDecodingQueue = OperationQueue()

        /// Data cache used by the pipeline.
        public var dataCache: DataCaching?

        /// This is here just for backward compatibility with `Loader`.
        internal var imageProcessor: (Image, ImageRequest) -> AnyImageProcessor? = { $1.processor }

        /// Image processing queue. Default maximum concurrent task count is 2.
        public var imageProcessingQueue = OperationQueue()

        /// `true` by default. If `true` the pipeline will combine the requests
        /// with the same `loadKey` into a single request. The request only gets
        /// cancelled when all the registered requests are.
        public var isDeduplicationEnabled = true

        /// `true` by default. It `true` the pipeline will rate limits the requests
        /// to prevent trashing of the underlying systems (e.g. `URLSession`).
        /// The rate limiter only comes into play when the requests are started
        /// and cancelled at a high rate (e.g. scrolling through a collection view).
        public var isRateLimiterEnabled = true

        /// `false` by default. If `true` the pipeline will try to produce a new
        /// image each time it receives a new portion of data from data loader.
        /// The decoder used by the image loading session determines whether
        /// to produce a partial image or not.
        public var isProgressiveDecodingEnabled = false

        /// If the data task is terminated (either because of a failure or a
        /// cancellation) and the image was partially loaded, the next load will
        /// resume where it was left off. Supports both validators (`ETag`,
        /// `Last-Modified`). The resumable downloads are enabled by default.
        public var isResumableDataEnabled = true

        /// If `true` pipeline will detects GIFs and set `animatedImageData`
        /// (`UIImage` property). It will also disable processing of such images,
        /// and alter the way cache cost is calculated. However, this will not
        /// enable actual animated image rendering. To do that take a look at
        /// satellite projects (FLAnimatedImage and Gifu plugins for Nuke).
        /// `false` by default (to preserve resources).
        public static var isAnimatedImageDataEnabled = false

        /// Enables experimental disk cache. The created disk cache is shared.
        /// If you call this function multiple times the shared cache is going to use
        /// the initial count and size limits. The public API for disk cache is
        /// going to be available in the future versions when it goes out of beta.
        /// - parameter countLimit: The maximum number of items. `1000` by default.
        /// - parameter sizeLimit: Size limit in bytes. `100 Mb` by default.
        public mutating func enableExperimentalAggressiveDiskCaching(countLimit: Int = 1000, sizeLimit: Int = 1024 * 1024 * 100, keyEncoder: @escaping (String) -> String?) {
            if DataCache.shared == nil {
                let cache = try? DataCache(name: "com.github.kean.Nuke.DataCache")
                cache?.countLimit = countLimit
                cache?.sizeLimit = sizeLimit
                cache?._keyEncoder = keyEncoder
                DataCache.shared = cache
            }
            self.dataCache = DataCache.shared
        }

        /// Creates default configuration.
        /// - parameter dataLoader: `DataLoader()` by default.
        /// - parameter imageCache: `Cache.shared` by default.
        public init(dataLoader: DataLoading = DataLoader(), imageCache: ImageCaching? = ImageCache.shared) {
            self.dataLoader = dataLoader
            self.imageCache = imageCache

            self.dataLoadingQueue.maxConcurrentOperationCount = 6
            self.imageDecodingQueue.maxConcurrentOperationCount = 1
            self.imageProcessingQueue.maxConcurrentOperationCount = 2
        }
    }

    /// Initializes `ImagePipeline` instance with the given configuration.
    /// - parameter configuration: `Configuration()` by default.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.rateLimiter = RateLimiter(queue: queue)
    }

    public convenience init(_ configure: (inout ImagePipeline.Configuration) -> Void) {
        var configuration = ImagePipeline.Configuration()
        configure(&configuration)
        self.init(configuration: configuration)
    }

    // MARK: Loading Images

    /// Loads an image with the given url.
    @discardableResult public func loadImage(with url: URL, progress: ImageTask.ProgressHandler? = nil, completion: ImageTask.Completion? = nil) -> ImageTask {
        return loadImage(with: ImageRequest(url: url), progress: progress, completion: completion)
    }

    /// Loads an image for the given request using image loading pipeline.
    @discardableResult public func loadImage(with request: ImageRequest, progress: ImageTask.ProgressHandler? = nil, completion: ImageTask.Completion? = nil) -> ImageTask {
        let task = ImageTask(taskId: Int(OSAtomicIncrement32(&nextTaskId)), request: request)
        queue.async {
            self._startLoadingImage(
                for: task,
                handlers: ImageLoadingSession.Handlers(progress: progress, completion: completion)
            )
        }
        return task
    }

    private func _startLoadingImage(for task: ImageTask, handlers: ImageLoadingSession.Handlers) {
        // Fast preflight check.
        guard !task.cts.isCancelling else {
            task.metrics.wasCancelled = true
            task.metrics.endDate = Date()
            return
        }

        // Read memory cache.
        if task.request.memoryCacheOptions.isReadAllowed,
            let response = configuration.imageCache?.cachedResponse(for: task.request) {
            DispatchQueue.main.async {
                handlers.completion?(response, nil)
            }
            task.metrics.isMemoryCacheHit = true
            return
        }

        // Create a new image loading session or register with an existing one.
        let session = _createSession(with: task.request)
        task.session = session

        task.metrics.session = session.metrics
        task.metrics.wasSubscibedToExistingSession = !session.tasks.isEmpty

        // Register handler with a session.
        session.tasks[task] = handlers

        // Update priority for tasks.
        _updatePriority(for: session, task: task)

        // Already loaded and decoded the final image and started processing
        // for previously registered tasks (if any).
        if let image = session.decodedFinalImage {
            _session(session, processImage: image, for: task)
        }

        // Register cancellation and priority observers.
        task.cts.register { [weak self, weak task] in
            guard let task = task else { return }
            self?.queue.async {
                self?._imageTaskCancelled(task)
            }
        }

        task.priorityObserver = { [weak self, weak session] (task, _) in
            self?.queue.async {
                guard let session = session else { return }
                self?._updatePriority(for: session, task: task)
            }
        }
    }

    private func _updatePriority(for session: ImageLoadingSession, task: ImageTask) {
        let priority = ImageLoadingSession.priority(for: Array(session.tasks.keys))
        session.priority.value = priority
        // Update priority for processing operations (those are per image task,
        // not per image session).
        session.processingSessions[task]?.updatePriority()
    }

    // Cancel the session in case all handlers were removed.
    fileprivate func _imageTaskCancelled(_ task: ImageTask) {
        task.metrics.wasCancelled = true
        task.metrics.endDate = Date()

        if let session = task.session { // executing == true
            session.tasks[task] = nil

            // When all registered tasks are cancelled, the session is
            // deallocated and the underlying operation is cancelled
            // automatically.
            session.processingSessions[task] = nil

            // Cancel the session when there are no remaining tasks.
            if session.tasks.isEmpty {
                _tryToSaveResumableData(for: session)
                session.cts.cancel()
                session.metrics.wasCancelled = true
                _sessionDidFinish(session)
            }
        }

        guard let didFinishTask = didFinishCollectingMetrics else { return }
        DispatchQueue.main.async { didFinishTask(task, task.metrics) }
    }

    // MARK: ImageLoadingSession (Managing)

    private func _createSession(with request: ImageRequest) -> ImageLoadingSession {
        // Check if session for the given key already exists.
        //
        // This part is more clever than I would like. The reason why we need a
        // key even when deduplication is disabled is to have a way to retain
        // a session by storing it in `sessions` dictionary.
        let key: AnyHashable = configuration.isDeduplicationEnabled ? ImageRequest.LoadKey(request: request) : UUID()
        if let session = sessions[key] {
            return session
        }
        let session = ImageLoadingSession(sessionId: Int(OSAtomicIncrement32(&nextSessionId)), request: request, key: key)
        sessions[key] = session
        _loadImage(for: session) // Start the pipeline
        return session
    }

    // MARK: Pipeline (Loading Data)

    private func _loadImage(for session: ImageLoadingSession) {
        // Use rate limiter to prevent trashing of the underlying systems
        if configuration.isRateLimiterEnabled {
            // Rate limiter is synchronized on pipeline's queue. Delayed work is
            // executed asynchronously also on this same queue.
            rateLimiter.execute(token: session.cts.token) { [weak self, weak session] in
                guard let session = session else { return }
                self?._checkDiskCache(for: session)
            }
        } else { // Start loading immediately.
            _checkDiskCache(for: session)
        }
    }

    private func _checkDiskCache(for session: ImageLoadingSession) {
        guard let cache = configuration.dataCache, let key = session.request.urlString else {
            _loadData(for: session) // Skip disk cache lookup, load data
            return
        }

        session.metrics.checkDiskCacheStartDate = Date()

        // Disk cache lookup (Experimenal)
        let task = cache.cachedData(for: key) { [weak self, weak session] data in
            guard let session = session else { return }
            session.metrics.checkDiskCacheEndDate = Date()
            self?.queue.async {
                if let data = data {
                    self?._decodeFinalImage(for: session, data: data)
                } else {
                    self?._loadData(for: session)
                }
            }
        }
        session.token.register { task.cancel() }
    }

    private func _loadData(for session: ImageLoadingSession) {
        guard !session.token.isCancelling else { return } // Preflight check

        // Wrap data request in an operation to limit maximum number of
        // concurrent data tasks.
        let operation = Operation(starter: { [weak self, weak session] finish in
            guard let session = session else { finish(); return }
            self?.queue.async {
                self?._actuallyLoadData(for: session, finish: finish)
            }
        })
        _session(session, enqueue: operation, on: configuration.dataLoadingQueue)
    }

    // This methods gets called inside data loading operation (Operation).
    private func _actuallyLoadData(for session: ImageLoadingSession, finish: @escaping () -> Void) {
        session.metrics.loadDataStartDate = Date()

        var urlRequest = session.request.urlRequest

        // Read and remove resumable data from cache (we're going to insert it
        // back in the cache if the request fails to complete again).
        if configuration.isResumableDataEnabled,
            let resumableData = ResumableData.removeResumableData(for: urlRequest) {
            // Update headers to add "Range" and "If-Range" headers
            resumableData.resume(request: &urlRequest)
            // Save resumable data so that we could use it later (we need to
            // verify that server returns "206 Partial Content" before using it.
            session.resumableData = resumableData

            // Collect metrics
            session.metrics.wasResumed = true
            session.metrics.resumedDataCount = resumableData.data.count
        }

        let task = configuration.dataLoader.loadData(
            with: urlRequest,
            didReceiveData: { [weak self, weak session] (data, response) in
                self?.queue.async {
                    guard let session = session else { return }
                    self?._session(session, didReceiveData: data, response: response)
                }
            },
            completion: { [weak self, weak session] (error) in
                finish() // Important! Mark Operation as finished.
                self?.queue.async {
                    guard let session = session else { return }
                    self?._session(session, didFinishLoadingDataWithError: error)
                }
        })
        session.token.register {
            task.cancel()
            finish() // Make sure we always finish the operation.
        }
    }

    private func _session(_ session: ImageLoadingSession, didReceiveData chunk: Data, response: URLResponse) {
        // Check if this is the first response.
        if session.urlResponse == nil {
            // See if the server confirmed that we can use the resumable data.
            if let resumableData = session.resumableData {
                if ResumableData.isResumedResponse(response) {
                    session.data = resumableData.data
                    session.metrics.serverConfirmedResume = true
                }
                session.resumableData = nil // Get rid of resumable data anyway
            }
        }

        // Append data and save response
        session.data.append(chunk)
        session.urlResponse = response

        // Collect metrics
        session.metrics.downloadedDataCount = ((session.metrics.downloadedDataCount ?? 0) + chunk.count)

        // Update tasks' progress and call progress closures if any
        let (completed, total) = (Int64(session.data.count), response.expectedContentLength)
        let tasks = session.tasks
        DispatchQueue.main.async {
            for (task, handlers) in tasks {
                (task.completedUnitCount, task.totalUnitCount) = (completed, total)
                handlers.progress?(nil, completed, total)
                task._progress?.completedUnitCount = completed
                task._progress?.totalUnitCount = total
            }
        }

        // Check if progressive decoding is enabled (disabled by default)
        if configuration.isProgressiveDecodingEnabled {
            // Check if we haven't loaded an entire image yet. We give decoder
            // an opportunity to decide whether to decode this chunk or not.
            // In case `expectedContentLength` is undetermined (e.g. 0) we
            // don't allow progressive decoding.
            guard session.data.count < response.expectedContentLength else { return }

            _setNeedsDecodePartialImage(for: session)
        }
    }

    private func _session(_ session: ImageLoadingSession, didFinishLoadingDataWithError error: Swift.Error?) {
        session.metrics.loadDataEndDate = Date()

        if let error = error {
            _tryToSaveResumableData(for: session)
            _session(session, didFailWithError: .dataLoadingFailed(error))
            return
        }

        let data = session.data
        session.data.removeAll() // We no longer need the data stored in session.

        _decodeFinalImage(for: session, data: data)
    }

    // MARK: Pipeline (Decoding)

    private func _setNeedsDecodePartialImage(for session: ImageLoadingSession) {
        guard session.decodingOperation?.operation == nil else {
            return // Already enqueued an operation.
        }
        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            self?._actuallyDecodePartialImage(for: session)
        }
        _enqueueDecodingOperation(operation, for: session)
    }

    private func _actuallyDecodePartialImage(for session: ImageLoadingSession) {
        // As soon as we get a chance to execute, grab the latest available
        // data, create a decoder (if necessary) and decode the data.
        let (data, decoder): (Data, ImageDecoding?) = queue.sync {
            let data = session.data
            let decoder = _decoder(for: session, data: data)
            return (data, decoder)
        }

        // Produce partial image
        if let image = decoder?.decode(data: data, isFinal: false) {
            let scanNumber: Int? = (decoder as? ImageDecoder)?.numberOfScans
            queue.async {
                let container = ImageContainer(image: image, isFinal: false, scanNumber: scanNumber)
                for task in session.tasks.keys {
                    self._session(session, processImage: container, for: task)
                }
            }
        }
    }

    private func _decodeFinalImage(for session: ImageLoadingSession, data: Data) {
        // Basic sanity checks, should never happen in practice.
        guard !data.isEmpty, let decoder = _decoder(for: session, data: data) else {
            _session(session, didFailWithError: .decodingFailed)
            return
        }

        let metrics = session.metrics
        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            metrics.decodeStartDate = Date()
            // Produce final image
            let image = autoreleasepool {
                decoder.decode(data: data, isFinal: true)
            }
            metrics.decodeEndDate = Date()
            self?.queue.async {
                let container = image.map {
                    ImageContainer(image: $0, isFinal: true, scanNumber: nil)
                }
                self?._session(session, didDecodeFinalImage: container, data: data)
            }
        }
        _enqueueDecodingOperation(operation, for: session)
    }

    private func _enqueueDecodingOperation(_ operation: Foundation.Operation, for session: ImageLoadingSession) {
        _session(session, enqueue: operation, on: configuration.imageDecodingQueue)
        session.decodingOperation = DisposableOperation(operation)
    }

    // Lazily creates a decoder if necessary.
    private func _decoder(for session: ImageLoadingSession, data: Data) -> ImageDecoding? {
        // Return existing one.
        if let decoder = session.decoder { return decoder }

        // Basic sanity checks.
        guard !data.isEmpty else { return nil }

        let context = ImageDecodingContext(request: session.request, urlResponse: session.urlResponse, data: data)
        let decoder = configuration.imageDecoder(context)
        session.decoder = decoder
        return decoder
    }

    private func _tryToSaveResumableData(for session: ImageLoadingSession) {
        // Try to save resumable data in case the task was cancelled
        // (`URLError.cancelled`) or failed to complete with other error.
        if configuration.isResumableDataEnabled,
            let response = session.urlResponse, !session.data.isEmpty,
            let resumableData = ResumableData(response: response, data: session.data) {
            ResumableData.storeResumableData(resumableData, for: session.request.urlRequest)
        }
    }

    private func _session(_ session: ImageLoadingSession, didDecodeFinalImage image: ImageContainer?, data: Data) {
        session.decoder = nil // Decoding session completed, no longer need decoder.
        session.decodedFinalImage = image

        guard let image = image else {
            _session(session, didFailWithError: .decodingFailed)
            return
        }

        // Store data in data cache (in case it's enabled))
        if !data.isEmpty, let dataCache = configuration.dataCache, let key = session.request.urlString {
            dataCache.storeData(data, for: key)
        }

        for task in session.tasks.keys {
            _session(session, processImage: image, for: task)
        }
    }

    // MARK: Pipeline (Processing)

    /// Processes the input image for each of the given tasks. The image is processed
    /// only once for the equivalent processors.
    /// - parameter completion: Will get called synchronously if processing is not
    /// required. If it is will get called on `self.queue` when processing is finished.
    private func _session(_ session: ImageLoadingSession, processImage image: ImageContainer, for task: ImageTask) {
        let isFinal = image.isFinal
        guard let processor = _processor(for: image.image, request: task.request) else {
            _session(session, didProcessImage: image.image, isFinal: isFinal, metrics: TaskMetrics(), for: task)
            return // No processing needed.
        }

        if !image.isFinal && session.processingSessions[task] != nil {
            return  // Back pressure - we'are already busy processing another partial image
        }

        // Find existing session or create a new one.
        let processingSession = session.processingSessions.values.first {
            $0.processor == processor && $0.image.image === image.image
        } ?? {
            let processingSession = ImageProcessingSession(processor: processor, image: image)
            let operation = BlockOperation { [weak self, weak session, weak processingSession] in
                var metrics = TaskMetrics()
                metrics.start()
                let output: Image? = autoreleasepool {
                    processor.process(image: image, request: task.request)
                }
                metrics.end()

                self?.queue.async {
                    guard let session = session else { return }
                    for task in (processingSession?.tasks ?? []) {
                        if session.processingSessions[task] === processingSession {
                            session.processingSessions[task] = nil
                        }
                        self?._session(session, didProcessImage: output, isFinal: isFinal, metrics: metrics, for: task)
                    }
                }
            }
            configuration.imageProcessingQueue.addOperation(operation)
            processingSession.operation = operation
            return processingSession
        }()

        // Register task for a session.
        processingSession.tasks.insert(task)
        session.processingSessions[task] = processingSession
        processingSession.updatePriority()
    }

    private func _processor(for image: Image, request: ImageRequest) -> AnyImageProcessor? {
        if Configuration.isAnimatedImageDataEnabled && image.animatedImageData != nil {
            return nil // Don't process animated images.
        }
        return configuration.imageProcessor(image, request)
    }

    private func _session(_ session: ImageLoadingSession, didProcessImage image: Image?, isFinal: Bool, metrics: TaskMetrics, for task: ImageTask) {
        if isFinal {
            task.metrics.processStartDate = metrics.startDate
            task.metrics.processEndDate = metrics.endDate
            let error: Error?  = (image == nil ? .processingFailed : nil)
            _session(session, didCompleteTask: task, image: image, error: error)
        } else {
            guard let image = image else { return }
            _session(session, didProducePartialImage: image, for: task)
        }
    }

    // MARK: ImageLoadingSession (Callbacks)

    private func _session(_ session: ImageLoadingSession, didProducePartialImage image: Image, for task: ImageTask) {
        // Check if we haven't completed the session yet by producing a final image
        // or cancelling the task.
        guard sessions[session.key] === session else { return }

        let response = ImageResponse(image: image, urlResponse: session.urlResponse)
        if let handlers = session.tasks[task], let progress = handlers.progress {
            DispatchQueue.main.async {
                progress(response, task.completedUnitCount, task.totalUnitCount)
            }
        }
    }

    private func _session(_ session: ImageLoadingSession, didCompleteTask task: ImageTask, image: Image?, error: Error?) {
        let response = image.map {
            ImageResponse(image: $0, urlResponse: session.urlResponse)
        }
        // Store response in memory cache if allowed.
        if let response = response, task.request.memoryCacheOptions.isWriteAllowed {
            configuration.imageCache?.storeResponse(response, for: task.request)
        }
        // Dispatch completion blocks.
        if let handlers = session.tasks.removeValue(forKey: task) {
            task.metrics.endDate = Date()
            DispatchQueue.main.async {
                handlers.completion?(response, error)
                self.didFinishCollectingMetrics?(task, task.metrics)
            }
        }
        if session.tasks.isEmpty {
            _sessionDidFinish(session)
        }
    }

    private func _session(_ session: ImageLoadingSession, didFailWithError error: Error) {
        for task in session.tasks.keys {
            _session(session, didCompleteTask: task, image: nil, error: error)
        }
    }

    private func _sessionDidFinish(_ session: ImageLoadingSession) {
        // Check if session is still registered.
        guard sessions[session.key] === session else { return }
        session.metrics.endDate = Date()
        sessions[session.key] = nil
    }

    // MARK: Misc

    private func _session(_ session: ImageLoadingSession, enqueue operation: Foundation.Operation, on queue: Foundation.OperationQueue) {
        operation.queuePriority = session.priority.value.queuePriority
        session.priority.observe { [weak operation] in
            operation?.queuePriority = $0.queuePriority
        }
        session.token.register { [weak operation] in
            operation?.cancel()
        }
        queue.addOperation(operation)
    }

    // MARK: Errors

    /// Represents all possible image pipeline errors.
    public enum Error: Swift.Error, CustomDebugStringConvertible {
        /// Data loader failed to load image data with a wrapped error.
        case dataLoadingFailed(Swift.Error)
        /// Decoder failed to produce a final image.
        case decodingFailed
        /// Processor failed to produce a final image.
        case processingFailed

        public var debugDescription: String {
            switch self {
            case let .dataLoadingFailed(error): return "Failed to load image data: \(error)"
            case .decodingFailed: return "Failed to create an image from the image data"
            case .processingFailed: return "Failed to process the image"
            }
        }
    }
}

// MARK: - ImageLoadingSession

/// A image loading session. During a lifetime of a session handlers can
/// subscribe to and unsubscribe from it.
private final class ImageLoadingSession {
    let sessionId: Int

    /// The original request with which the session was created.
    let request: ImageRequest
    let key: AnyHashable // loading key
    let cts = _CancellationTokenSource()
    var token: _CancellationToken { return cts.token }

    // Registered image tasks.
    var tasks = [ImageTask: Handlers]()

    struct Handlers {
        let progress: ImageTask.ProgressHandler?
        let completion: ImageTask.Completion?
    }

    // Data loading session.
    var urlResponse: URLResponse?
    var resumableData: ResumableData?
    lazy var data = Data()

    // Decoding session.
    var decoder: ImageDecoding?
    var decodedFinalImage: ImageContainer? // Decoding result
    var decodingOperation: DisposableOperation?

    // Processing sessions.
    var processingSessions = [ImageTask: ImageProcessingSession]()

    // Metrics that we collect during the lifetime of a session.
    let metrics: ImageTaskMetrics.SessionMetrics

    init(sessionId: Int, request: ImageRequest, key: AnyHashable) {
        self.sessionId = sessionId
        self.request = request
        self.key = key
        self.metrics = ImageTaskMetrics.SessionMetrics(sessionId: sessionId)
        self.priority = Property(value: request.priority)
    }

    static func priority(for tasks: [ImageTask]) -> ImageRequest.Priority {
        return tasks.map { $0.request.priority }.max() ?? .normal
    }

    var priority: Property<ImageRequest.Priority>
}

private final class ImageProcessingSession {
    let processor: AnyImageProcessor
    let image: ImageContainer
    var tasks = Set<ImageTask>()
    weak var operation: Foundation.Operation?

    deinit {
        operation?.cancel()
    }

    init(processor: AnyImageProcessor, image: ImageContainer) {
        self.processor = processor; self.image = image
    }

    func updatePriority() {
        operation?.queuePriority = ImageLoadingSession.priority(for: Array(tasks)).queuePriority
    }
}

struct ImageContainer {
    let image: Image
    let isFinal: Bool
    let scanNumber: Int?
}
