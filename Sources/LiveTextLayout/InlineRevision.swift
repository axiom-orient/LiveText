import Foundation

/// The preparation policy that participates in canonical prepared-document identity.
/// A serialized prepared document carries this context so its revision can be
/// recomputed instead of trusting an opaque caller-supplied digest.
public struct InlinePreparationIdentityContext: Sendable, Hashable, Codable {
  public enum Mode: String, Sendable, Hashable, Codable {
    case full
    case cancellationAware
  }

  public let mode: Mode
  public let limits: InlinePreparationLimits

  public init(mode: Mode, limits: InlinePreparationLimits = .default) {
    self.mode = mode
    self.limits = limits
  }

  public static func full(
    limits: InlinePreparationLimits = .default
  ) -> InlinePreparationIdentityContext {
    InlinePreparationIdentityContext(mode: .full, limits: limits)
  }

  public static func cancellationAware(
    limits: InlinePreparationLimits = .default
  ) -> InlinePreparationIdentityContext {
    InlinePreparationIdentityContext(mode: .cancellationAware, limits: limits)
  }

  /// Validates the profile before content admission or canonical hashing.
  func validateLimits() throws {
    guard limits.maximumAtoms >= 0,
      limits.maximumTextUTF16Units >= 0,
      limits.maximumGraphemes >= 0,
      limits.maximumGlyphs >= 0,
      limits.maximumRuns >= 0,
      limits.maximumImageAtoms >= 0,
      limits.maximumCancellableAtomUTF16Units >= 0,
      limits.maximumCancellableAtomGlyphs >= 0,
      limits.maximumCancellableAtomRuns >= 0,
      limits.maximumWritingStrokes > 0,
      limits.maximumWritingStrokes <= InlinePreparationLimits.maximumWritingStrokesCeiling,
      limits.maximumWritingPoints > 0,
      limits.maximumWritingPoints <= InlinePreparationLimits.maximumWritingPointsCeiling
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  package var includeTextKernelPreparation: Bool {
    mode == .full
  }
}

/// Incrementally builds the fixed preparation revision used by layout continuations.
///
/// Each atom pair is encoded with the package-owned canonical typed encoder and
/// fed directly to SHA-256. Foundation serialization is not an identity authority.
struct InlineRevisionBuilder {
  private struct Profile: Encodable {
    let includeTextKernelPreparation: Bool
    let limits: InlinePreparationLimits
  }

  private struct AtomPair: Encodable {
    let documentAtom: InlineAtom
    let preparedAtom: PreparedInlineDocument.Atom
  }

  private var hasher = StableSHA256()

  init(
    includeTextKernelPreparation: Bool,
    limits: InlinePreparationLimits
  ) throws {
    let profile = try CanonicalIdentityEncoder.encode(
      Profile(
        includeTextKernelPreparation: includeTextKernelPreparation,
        limits: limits
      )
    )
    hasher.update(data: Data("Packages/LiveText/inline-preparation-revision-v3".utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: profile)
  }

  mutating func append(
    documentAtom: InlineAtom,
    preparedAtom: PreparedInlineDocument.Atom
  ) throws {
    let pair = try CanonicalIdentityEncoder.encode(
      AtomPair(documentAtom: documentAtom, preparedAtom: preparedAtom)
    )
    hasher.update(data: Data([1]))
    hasher.update(data: pair)
  }

  func finalizedHex() -> String {
    var copy = self
    copy.hasher.update(data: Data([0xff]))
    let digest = copy.hasher.finalize()
    var encoded = [UInt8]()
    encoded.reserveCapacity(64)
    let digits = Array("0123456789abcdef".utf8)
    for byte in digest {
      encoded.append(digits[Int(byte >> 4)])
      encoded.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
  }
}

func canonicalInlinePreparationRevision(
  document: InlineDocument,
  preparedAtoms: [PreparedInlineDocument.Atom],
  identityContext: InlinePreparationIdentityContext,
  cancellation: InlineCancellationCheck = {}
) throws -> String {
  try identityContext.validateLimits()

  var builder = try InlineRevisionBuilder(
    includeTextKernelPreparation: identityContext.includeTextKernelPreparation,
    limits: identityContext.limits
  )
  for (documentAtom, preparedAtom) in zip(document.atoms, preparedAtoms) {
    try cancellation()
    try builder.append(documentAtom: documentAtom, preparedAtom: preparedAtom)
  }
  try cancellation()
  return builder.finalizedHex()
}
