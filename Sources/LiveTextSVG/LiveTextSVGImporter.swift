import Foundation

/// Strict, dependency-free SVG v1 path importer.
///
/// The parser accepts bounded SVG geometry (`svg`, `g`, `path`, and the basic
/// shape elements used by authored illustration assets), and converts every
/// primitive and source arc into a bounded sequence of cubic commands.
/// Unsupported paint or semantics are reported instead of being silently
/// dropped.
public enum LiveTextSVGImporter {
  public static func document(
    from data: Data,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGImportedDocument {
    try SVGDocumentParser(data: data, options: options).parse()
  }

  public static func document(
    from source: String,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGImportedDocument {
    try document(from: Data(source.utf8), options: options)
  }
}

/// Imports static, multi-colour sticker artwork using the same bounded XML,
/// primitive, and path parser as live text. It never executes scripts or
/// follows external references.
public enum LiveTextSVGArtworkImporter {
  public static func document(
    from data: Data,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGArtworkDocument {
    try SVGDocumentParser(data: data, options: options, mode: .artwork).parseArtwork()
  }

  public static func document(
    from source: String,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGArtworkDocument {
    try document(from: Data(source.utf8), options: options)
  }
}
