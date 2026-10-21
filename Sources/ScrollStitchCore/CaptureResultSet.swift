import Foundation

/// Shared only so empty-startup recovery can validate known analysis metadata.
public struct CaptureAnalysisSession:Codable {
    public var version=2
    public let runID:UUID
    public let sourceIdentity:String
    public let recipe:String
    public let revision:UInt64
    public init(runID:UUID,sourceIdentity:String,recipe:String,revision:UInt64) {
        self.runID=runID;self.sourceIdentity=sourceIdentity;self.recipe=recipe;self.revision=revision
    }
    public func validate() throws {
        guard version==2 else {throw ScrollStitchError.unsupportedSchema}
        guard [sourceIdentity,recipe].allSatisfy({$0.count==64 && $0.allSatisfy(\.isHexDigit)}) else {throw ScrollStitchError.corruptData}
    }
}

public enum CaptureAssemblyStatus: String, Codable, Sendable {
    case complete, separated, staticFrame, noUsableContent, recoverableFailure
}

public struct CaptureResultPage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let document: Int
    public let page: Int
    public let result: ResultManifest
    public init(sourceIdentity:String, recipe:String, document:Int, page:Int, result:ResultManifest) {
        id=TaskStore.digest(data:Data("\(sourceIdentity)|\(recipe)|\(document)|\(page)|\(result.format)".utf8))
        self.document=document;self.page=page;self.result=result
    }
}

/// Atomic index over immutable, independently verified files. Pagination does not
/// imply missing content; disconnected documents do, and retain a visible reason.
public struct CaptureResultSet: Codable, Equatable, Sendable {
    public var version=2
    public let taskID:UUID
    public let revision:UInt64
    public let sourceIdentity:String
    public let recipe:String
    public let selectionFingerprint:String
    public let status:CaptureAssemblyStatus
    public let pages:[CaptureResultPage]
    public let gaps:[String]
    /// Only complete output can bypass reconstruction when resuming a save.
    public var readyForPhotoSave: Bool {
        (status == .complete || status == .staticFrame) && !pages.isEmpty && gaps.isEmpty
    }
    public init(taskID:UUID,revision:UInt64,sourceIdentity:String,recipe:String,selectionFingerprint:String,
                status:CaptureAssemblyStatus,pages:[CaptureResultPage],gaps:[String]) {
        self.taskID=taskID;self.revision=revision;self.sourceIdentity=sourceIdentity;self.recipe=recipe
        self.selectionFingerprint=selectionFingerprint;self.status=status;self.pages=pages;self.gaps=gaps
    }
    public func validate() throws {
        guard version==2 else { throw ScrollStitchError.unsupportedSchema }
        let hashes=[sourceIdentity,recipe,selectionFingerprint]
        guard hashes.allSatisfy({$0.count==64 && $0.allSatisfy(\.isHexDigit)}),pages.count<=512,
              Set(pages.map(\.id)).count==pages.count,Set(pages.map{$0.result.id}).count==pages.count,
              gaps.allSatisfy({!$0.isEmpty && $0.count<=240}) else { throw ResultExportError.invalidResult }
        if status == .complete || status == .staticFrame {
            guard !pages.isEmpty,gaps.isEmpty,Set(pages.map(\.document)).count==1 else { throw ResultExportError.invalidResult }
        }
        if status == .separated { guard pages.count>1,!gaps.isEmpty else { throw ResultExportError.invalidResult } }
        if status == .noUsableContent { guard pages.isEmpty else { throw ResultExportError.invalidResult } }
        var lastDocument = -1,lastPage = -1
        for page in pages {
            try page.result.validate()
            guard page.result.taskID==taskID,page.result.revision==revision,
                  page.document>=0,page.page>=0,page.document>=lastDocument,
                  page.page == (page.document==lastDocument ? lastPage+1:0),
                  page.id==CaptureResultPage(sourceIdentity:sourceIdentity,recipe:recipe,document:page.document,page:page.page,result:page.result).id else {
                throw ResultExportError.invalidResult
            }
            lastDocument=page.document;lastPage=page.page
        }
    }
}
