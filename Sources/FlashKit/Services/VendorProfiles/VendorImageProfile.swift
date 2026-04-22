import Foundation

protocol VendorImageProfile {
    var id: VendorProfileID { get }
    var acceptedImageKinds: Set<ClassifiedImageKind> { get }

    func match(in context: ImageClassificationContext) -> VendorProfileMatch?
}
