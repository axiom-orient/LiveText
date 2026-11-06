@testable import ChalkLineEffects
import CoreGraphics
import LiveTextEffects
import SwiftUI
import XCTest

@MainActor
final class ChalkWritingFramePlanTests: XCTestCase {
  private let duration = 4.0

  func testWriteBoundariesAndGapUsePrefixRanges() throws {
    let timings = try makeTimings([(0, 1), (1.5, 2.5), (3, 4)])

    let atStart = plan(.write, progress: 0, timings: timings)
    XCTAssertEqual(atStart.fullRange, 0..<0)
    XCTAssertEqual(atStart.hiddenRange, 1..<3)
    XCTAssertEqual(atStart.partialStroke, .init(index: 0, fraction: 0))
    XCTAssertEqual(atStart.fractionEvaluationCount, 1)

    // At the first stroke's end the old per-stroke implementation returned a
    // full first stroke and no active slice during the inter-stroke gap.
    let inGap = plan(.write, progress: 0.25, timings: timings)
    XCTAssertEqual(inGap.fullRange, 0..<1)
    XCTAssertEqual(inGap.hiddenRange, 1..<3)
    XCTAssertNil(inGap.partialStroke)
    XCTAssertEqual(inGap.fractionEvaluationCount, 0)

    let nextStart = plan(.write, progress: 0.375, timings: timings)
    XCTAssertEqual(nextStart.fullRange, 0..<1)
    XCTAssertEqual(nextStart.hiddenRange, 2..<3)
    XCTAssertEqual(nextStart.partialStroke?.index, 1)
    XCTAssertEqual(nextStart.partialStroke?.fraction, 0)

    let active = plan(.write, progress: 0.5, timings: timings)
    XCTAssertEqual(active.fullRange, 0..<1)
    XCTAssertEqual(active.hiddenRange, 2..<3)
    XCTAssertEqual(active.partialStroke?.index, 1)
    XCTAssertEqual(
      active.partialStroke?.fraction,
      WritingPlayback.strokeFraction(
        at: 2,
        timing: timings[1],
        motion: .uniform,
        seed: 0
      )
    )

    let atEnd = plan(.write, progress: 1, timings: timings)
    XCTAssertEqual(atEnd.fullRange, 0..<3)
    XCTAssertEqual(atEnd.hiddenRange, 3..<3)
    XCTAssertNil(atEnd.partialStroke)
    XCTAssertEqual(atEnd.fractionEvaluationCount, 0)
  }

  func testEraseForwardUsesSuffixRangesAtExactStartAndEnd() throws {
    let timings = try makeTimings([(0, 1), (1.5, 2.5), (3, 4)])

    let atStart = plan(.eraseForward, progress: 0, timings: timings)
    XCTAssertFalse(atStart.isPrefix)
    XCTAssertEqual(atStart.hiddenRange, 0..<0)
    XCTAssertEqual(atStart.fullRange, 1..<3)
    XCTAssertEqual(atStart.partialStroke, .init(index: 0, fraction: 0))

    let inGap = plan(.eraseForward, progress: 0.25, timings: timings)
    XCTAssertEqual(inGap.hiddenRange, 0..<1)
    XCTAssertEqual(inGap.fullRange, 1..<3)
    XCTAssertNil(inGap.partialStroke)
    XCTAssertEqual(inGap.fractionEvaluationCount, 0)

    let nextStart = plan(.eraseForward, progress: 0.375, timings: timings)
    XCTAssertEqual(nextStart.hiddenRange, 0..<1)
    XCTAssertEqual(nextStart.fullRange, 2..<3)
    XCTAssertEqual(nextStart.partialStroke?.index, 1)
    XCTAssertEqual(nextStart.partialStroke?.fraction, 0)

    let active = plan(.eraseForward, progress: 0.5, timings: timings)
    XCTAssertEqual(active.hiddenRange, 0..<1)
    XCTAssertEqual(active.fullRange, 2..<3)
    XCTAssertEqual(active.partialStroke?.index, 1)
    XCTAssertEqual(active.fractionEvaluationCount, 1)

    let atEnd = plan(.eraseForward, progress: 1, timings: timings)
    XCTAssertEqual(atEnd.hiddenRange, 0..<3)
    XCTAssertEqual(atEnd.fullRange, 3..<3)
    XCTAssertNil(atEnd.partialStroke)
  }

  func testEraseForwardPainterOrderKeepsActiveStrokeBeforeFutureStrokes() throws {
    let timings = try makeTimings([(0, 1), (1, 2), (2, 3)])
    let frame = plan(
      .eraseForward,
      progress: 0.5,
      timings: timings,
      duration: 3
    )
    XCTAssertEqual(frame.partialStroke?.index, 1)
    XCTAssertEqual(frame.fullRange, 2..<3)

    // The Canvas branch paints this same sequence: hidden prefix, active
    // suffix, then future full strokes in ascending layer order.
    var painterOrder: [String] = []
    if let partial = frame.partialStroke {
      painterOrder.append("partial-\(partial.index)")
    }
    painterOrder.append(contentsOf: frame.fullRange.map { "full-\($0)" })
    XCTAssertEqual(painterOrder, ["partial-1", "full-2"])
  }

  func testEraseReverseReversesTimelineWithoutChangingPrefixBoundaries() throws {
    let timings = try makeTimings([(0, 1), (1.5, 2.5), (3, 4)])

    let atStart = plan(.eraseReverse, progress: 0, timings: timings)
    XCTAssertTrue(atStart.isPrefix)
    XCTAssertEqual(atStart.fullRange, 0..<3)
    XCTAssertEqual(atStart.hiddenRange, 3..<3)
    XCTAssertNil(atStart.partialStroke)

    // Reverse progress 0.625 maps to timeline time 1.5, the exact second
    // stroke start; the first stroke remains full and the rest is hidden.
    let nextStart = plan(.eraseReverse, progress: 0.625, timings: timings)
    XCTAssertEqual(nextStart.fullRange, 0..<1)
    XCTAssertEqual(nextStart.hiddenRange, 2..<3)
    XCTAssertEqual(nextStart.partialStroke, .init(index: 1, fraction: 0))

    let inGap = plan(.eraseReverse, progress: 0.75, timings: timings)
    XCTAssertEqual(inGap.fullRange, 0..<1)
    XCTAssertEqual(inGap.hiddenRange, 1..<3)
    XCTAssertNil(inGap.partialStroke)

    let atEnd = plan(.eraseReverse, progress: 1, timings: timings)
    XCTAssertEqual(atEnd.fullRange, 0..<0)
    XCTAssertEqual(atEnd.hiddenRange, 1..<3)
    XCTAssertEqual(atEnd.partialStroke, .init(index: 0, fraction: 0))
  }

  func testUniformAndVariedFractionsAreEvaluatedOnlyForActiveStroke() throws {
    let timings = try makeTimings([(0, 1), (1, 2), (2, 3)])
    let seed: UInt64 = 0xC4_4841_4C_4B

    for animation in ChalkWritingAnimation.allCases {
      let uniform = plan(
        animation,
        progress: 0.5,
        timings: timings,
        motion: .uniform,
        seed: seed,
        duration: 3
      )
      XCTAssertEqual(uniform.fractionEvaluationCount, 1)
      XCTAssertEqual(uniform.partialStroke?.index, 1)
      XCTAssertEqual(
        uniform.partialStroke?.fraction,
        WritingPlayback.strokeFraction(
          at: 1.5,
          timing: timings[1],
          motion: .uniform,
          seed: seed
        )
      )

      let varied = plan(
        animation,
        progress: 0.5,
        timings: timings,
        motion: .varied,
        seed: seed,
        duration: 3
      )
      XCTAssertEqual(varied.fractionEvaluationCount, 1)
      XCTAssertEqual(
        varied.partialStroke?.fraction,
        WritingPlayback.strokeFraction(
          at: 1.5,
          timing: timings[1],
          motion: .varied,
          seed: seed
        )
      )
    }
  }

  func testSinglePointStrokeRemainsAVisibleDotOnlyOnTheVisibleSide() throws {
    let point = try WritingPoint(x: 3, y: 4, width: 2)
    let stroke = try WritingStroke(id: "dot", points: [point])
    let timing = try WritingStrokeTiming(
      layerIndex: 0,
      glyphIndex: 0,
      strokeIndex: 0,
      strokeID: "dot",
      startTime: 0,
      endTime: 1
    )
    let renderStroke = try ChalkWritingRenderPlan.Stroke(timing: timing, stroke: stroke)
    XCTAssertTrue(renderStroke.rendersAsDot(at: 0))
    XCTAssertTrue(renderStroke.rendersAsDot(at: 1))

    let writeAtStart = plan(.write, progress: 0, timings: [timing], duration: 1)
    XCTAssertEqual(writeAtStart.partialStroke?.fraction, 0)
    XCTAssertEqual(writeAtStart.fractionEvaluationCount, 1)
    let writeAtEnd = plan(.write, progress: 1, timings: [timing], duration: 1)
    XCTAssertNil(writeAtEnd.partialStroke)
    XCTAssertEqual(writeAtEnd.fullRange, 0..<1)

    let eraseAtEnd = plan(.eraseForward, progress: 1, timings: [timing], duration: 1)
    XCTAssertNil(eraseAtEnd.partialStroke)
    XCTAssertEqual(eraseAtEnd.hiddenRange, 0..<1)
    let eraseAtStart = plan(.eraseForward, progress: 0, timings: [timing], duration: 1)
    XCTAssertEqual(eraseAtStart.partialStroke?.fraction, 0)
    XCTAssertEqual(eraseAtStart.fullRange, 1..<1)
  }

  func testNonFiniteAndOutOfRangeProgressMatchesReferenceSliceClamping() throws {
    let timings = try makeTimings([(0, 1), (1, 2), (2, 3)])
    let values: [Double] = [.nan, -.infinity, .infinity, -0.25, 1.25]
    let seed: UInt64 = 0xC4_4841_4C_4B

    for animation in ChalkWritingAnimation.allCases {
      for progress in values {
        let frame = plan(
          animation,
          progress: progress,
          timings: timings,
          motion: .varied,
          seed: seed,
          duration: 3
        )
        for (index, timing) in timings.enumerated() {
          let referenceSlice = animation.strokeSlice(
            at: progress,
            duration: 3,
            timing: timing,
            motion: .varied,
            seed: seed
          )
          XCTAssertEqual(
            visibility(of: frame, index: index, count: timings.count),
            visibility(of: referenceSlice, animation: animation),
            "progress=\(progress), animation=\(animation), index=\(index)"
          )
        }
      }
    }
  }

  func testClassificationSearchAndFractionWorkStayBoundedAsStrokeCountGrows() throws {
    let smallTimings = try makeTimings(count: 1_024)
    let largeTimings = try makeTimings(count: 8_192)

    let small = plan(
      .write,
      progress: 0.5,
      timings: smallTimings,
      duration: 1_024
    )
    let large = plan(
      .write,
      progress: 0.5,
      timings: largeTimings,
      duration: 8_192
    )

    // The active fraction is evaluated once, irrespective of the number of
    // strokes. Binary search adds at most three comparisons when scaling 8x.
    XCTAssertEqual(small.fractionEvaluationCount, 1)
    XCTAssertEqual(large.fractionEvaluationCount, 1)
    XCTAssertLessThanOrEqual(small.timelineComparisonCount, 11)
    XCTAssertLessThanOrEqual(large.timelineComparisonCount, 14)
    XCTAssertLessThanOrEqual(
      large.timelineComparisonCount,
      small.timelineComparisonCount + 3
    )

    let gap = plan(
      .write,
      progress: 2_048.375 / 4_096,
      timings: try makeTimings(count: 8_192, strokeDuration: 0.25, gap: 0.25),
      duration: 4_096
    )
    XCTAssertEqual(gap.fractionEvaluationCount, 0)
  }

  func testImageRendererKeepsTextGeometryNonEmptyAcrossSmallAndLargeScales() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xC4_4841_4C_4B,
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 1,
      edgeRoughness: 0
    )
    let style = try ChalkWritingStyle(
      color: try ChalkColor(red: 0.94, green: 0.22, blue: 0.42),
      lineWidthMultiplier: 1,
      configuration: configuration
    )
    let view = ChalkWritingText(
      "A",
      style: style,
      animation: .write,
      motion: .uniform,
      progress: 1
    )

    let sizes = [CGSize(width: 160, height: 120), CGSize(width: 640, height: 480)]
    var normalizedBounds: [CGRect] = []
    for size in sizes {
      let evidence = try rasterEvidence(for: view, size: size)
      XCTAssertGreaterThan(evidence.nonTransparentPixelCount, 0)
      XCTAssertGreaterThan(evidence.bounds.width, size.width * 0.15)
      XCTAssertGreaterThan(evidence.bounds.height, size.height * 0.15)
      XCTAssertLessThan(evidence.bounds.minX, size.width * 0.85)
      XCTAssertGreaterThan(evidence.bounds.maxX, size.width * 0.15)
      normalizedBounds.append(normalize(evidence.bounds, in: size))
    }
    XCTAssertEqual(normalizedBounds[0].minX, normalizedBounds[1].minX, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].maxX, normalizedBounds[1].maxX, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].minY, normalizedBounds[1].minY, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].maxY, normalizedBounds[1].maxY, accuracy: 0.06)
  }

  func testImageRendererKeepsPathTransformDotAndStrokeStyleEvidenceAcrossScales() throws {
    let pathColor = try ChalkColor(red: 0.16, green: 0.72, blue: 0.96)
    let dotColor = try ChalkColor(red: 0.96, green: 0.72, blue: 0.16)
    let pathStyle = try ChalkPathStrokeStyle(
      color: pathColor,
      width: 8,
      lineCap: .square,
      lineJoin: .miter,
      miterLimit: 10
    )
    let dotStyle = try ChalkPathStrokeStyle(
      color: dotColor,
      width: 10,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 4
    )
    let point: (Double, Double) -> ChalkPathPoint = { x, y in
      try! ChalkPathPoint(x: x, y: y)
    }
    let pathStroke = try ChalkPathStroke(
      id: "styled-path",
      commands: [
        .move(to: point(10, 20)),
        .line(to: point(90, 20)),
        .line(to: point(62, 72)),
        .cubic(
          control1: point(42, 92),
          control2: point(78, 96),
          to: point(90, 82)
        ),
      ],
      style: pathStyle
    )
    // A zero-length line is a valid path stroke whose render plan uses the
    // same dot branch as the semantic renderer.
    let dotStroke = try ChalkPathStroke(
      id: "styled-dot",
      commands: [.move(to: point(50, 90)), .line(to: point(50, 90))],
      style: dotStyle
    )
    let scene = try ChalkPathScene(
      size: try WritingSize(width: 100, height: 100),
      strokes: [pathStroke, dotStroke],
      source: .custom(description: "frame-scale-test")
    )
    let preparation = try ChalkPathPreparation(scene: scene)
    let configuration = try WritingChalkConfiguration(
      seed: 0xC4_4841_4C_4B,
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 1,
      edgeRoughness: 0
    )
    let view = ChalkPathWriting(
      preparation: preparation,
      style: try ChalkWritingStyle(
        color: .white,
        lineWidthMultiplier: 1,
        configuration: configuration
      ),
      colorPolicy: .source,
      animation: .write,
      motion: .uniform,
      progress: 1
    )
    let reference = ReferenceChalkPathView(
      plan: preparation.renderPlan,
      style: try ChalkWritingStyle(
        color: .white,
        lineWidthMultiplier: 1,
        configuration: configuration
      ),
      colorPolicy: .source,
      animation: .write,
      motion: .uniform,
      progress: 1
    )

    let sizes = [CGSize(width: 160, height: 120), CGSize(width: 640, height: 480)]
    var normalizedBounds: [CGRect] = []
    for size in sizes {
      let evidence = try rasterEvidence(for: view, size: size)
      let referenceEvidence = try rasterEvidence(for: reference, size: size)
      XCTAssertGreaterThan(evidence.nonTransparentPixelCount, 0)
      XCTAssertEqual(evidence.bounds.minX, referenceEvidence.bounds.minX, accuracy: 1)
      XCTAssertEqual(evidence.bounds.minY, referenceEvidence.bounds.minY, accuracy: 1)
      XCTAssertEqual(evidence.bounds.maxX, referenceEvidence.bounds.maxX, accuracy: 1)
      XCTAssertEqual(evidence.bounds.maxY, referenceEvidence.bounds.maxY, accuracy: 1)
      // The source path spans most of the scene and the dot reaches the lower
      // edge; these broad bounds are stable under antialiasing and scale.
      XCTAssertLessThan(evidence.bounds.minX, size.width * 0.30)
      XCTAssertGreaterThan(evidence.bounds.maxX, size.width * 0.70)
      XCTAssertLessThan(evidence.bounds.minY, size.height * 0.30)
      XCTAssertGreaterThan(evidence.bounds.maxY, size.height * 0.75)
      normalizedBounds.append(normalize(evidence.bounds, in: size))
    }
    XCTAssertEqual(normalizedBounds[0].minX, normalizedBounds[1].minX, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].maxX, normalizedBounds[1].maxX, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].minY, normalizedBounds[1].minY, accuracy: 0.06)
    XCTAssertEqual(normalizedBounds[0].maxY, normalizedBounds[1].maxY, accuracy: 0.06)
  }

  func testImageRendererTextPixelsMatchReferenceAtSmallLargeAndIntermediateProgress() throws {
    let preparation = try ChalkWritingPreparation(
      text: "A",
      timing: WritingTimingOptions(
        pointsPerSecond: 180,
        minimumStrokeDuration: 0.32,
        interStrokeDelay: 0.08,
        interGlyphDelay: 0.12
      )
    )
    let configuration = try WritingChalkConfiguration(
      seed: 0xC4_4841_4C_4B,
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 1,
      edgeRoughness: 0
    )
    let style = try ChalkWritingStyle(
      color: try ChalkColor(red: 0.14, green: 0.82, blue: 0.38),
      lineWidthMultiplier: 1.15,
      configuration: configuration
    )
    let progress = 0.47
    let candidate = ChalkWritingText(
      preparation: preparation,
      style: style,
      animation: .write,
      motion: .uniform,
      progress: progress
    )
    let reference = ReferenceChalkWritingView(
      plan: preparation.renderPlanCache.renderPlan,
      style: style,
      animation: .write,
      motion: .uniform,
      progress: progress
    )

    for size in [CGSize(width: 160, height: 120), CGSize(width: 640, height: 480)] {
      let candidateEvidence = try rasterEvidence(for: candidate, size: size)
      let referenceEvidence = try rasterEvidence(for: reference, size: size)
      let metrics = try assertPixelEquivalent(
        candidateEvidence,
        referenceEvidence,
        label: "text progress=\(progress) size=\(size)"
      )
      XCTAssertGreaterThan(candidateEvidence.nonTransparentPixelCount, 0)
      XCTAssertLessThanOrEqual(metrics.differentPixelCount, max(24, metrics.pixelCount / 400))
      // CoreGraphics can quantize a transformed text edge differently at a
      // larger raster size. The observed max error is 22 of 255; 24 keeps
      // this guard tight while allowing that two-code-value margin.
      XCTAssertLessThanOrEqual(metrics.maxChannelError, 24)
      XCTAssertLessThanOrEqual(metrics.maxAlphaError, 24)
      XCTAssertLessThanOrEqual(metrics.meanChannelAbsoluteError, 0.20)
      XCTAssertLessThanOrEqual(metrics.meanAlphaAbsoluteError, 0.20)
    }
  }

  func testImageRendererPathPixelsMatchReferenceForSourceAndStyleColorsAtIntermediateProgress() throws {
    let scene = try makePixelComparisonPathScene()
    let preparation = try ChalkPathPreparation(scene: scene)
    let configuration = try WritingChalkConfiguration(
      seed: 0xC4_4841_4C_4B,
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 1,
      edgeRoughness: 0
    )
    let style = try ChalkWritingStyle(
      color: try ChalkColor(red: 0.88, green: 0.18, blue: 0.74),
      lineWidthMultiplier: 0.9,
      configuration: configuration
    )
    let progress = 0.43
    let sizes = [CGSize(width: 160, height: 120), CGSize(width: 640, height: 480)]

    for colorPolicy in ChalkPathColorPolicy.allCases {
      let candidate = ChalkPathWriting(
        preparation: preparation,
        style: style,
        colorPolicy: colorPolicy,
        animation: .write,
        motion: .uniform,
        progress: progress
      )
      let reference = ReferenceChalkPathView(
        plan: preparation.renderPlan,
        style: style,
        colorPolicy: colorPolicy,
        animation: .write,
        motion: .uniform,
        progress: progress
      )

      for size in sizes {
        let candidateEvidence = try rasterEvidence(for: candidate, size: size)
        let referenceEvidence = try rasterEvidence(for: reference, size: size)
        let metrics = try assertPixelEquivalent(
          candidateEvidence,
          referenceEvidence,
          label: "path policy=\(colorPolicy) progress=\(progress) size=\(size)"
        )
        XCTAssertGreaterThan(candidateEvidence.nonTransparentPixelCount, 0)
        XCTAssertLessThanOrEqual(metrics.differentPixelCount, max(24, metrics.pixelCount / 400))
        XCTAssertLessThanOrEqual(metrics.maxChannelError, 8)
        XCTAssertLessThanOrEqual(metrics.maxAlphaError, 8)
        XCTAssertLessThanOrEqual(metrics.meanChannelAbsoluteError, 0.20)
        XCTAssertLessThanOrEqual(metrics.meanAlphaAbsoluteError, 0.20)
      }
    }
  }

  func testImageRendererIsolatedDotPixelsMatchReferenceAndKeepSourceColor() throws {
    let dotColor = try ChalkColor(red: 0.96, green: 0.18, blue: 0.08)
    let styleColor = try ChalkColor(red: 0.08, green: 0.22, blue: 0.96)
    let dotStyle = try ChalkPathStrokeStyle(
      color: dotColor,
      width: 14,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 4
    )
    let point: (Double, Double) -> ChalkPathPoint = { x, y in
      try! ChalkPathPoint(x: x, y: y)
    }
    let dotStroke = try ChalkPathStroke(
      id: "isolated-dot",
      commands: [.move(to: point(50, 50)), .line(to: point(50, 50))],
      style: dotStyle
    )
    let scene = try ChalkPathScene(
      size: try WritingSize(width: 100, height: 100),
      strokes: [dotStroke],
      source: .custom(description: "isolated-dot-pixel-test")
    )
    let preparation = try ChalkPathPreparation(scene: scene)
    let configuration = try WritingChalkConfiguration(
      seed: 0xC4_4841_4C_4B,
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 1,
      edgeRoughness: 0
    )
    let style = try ChalkWritingStyle(
      color: styleColor,
      lineWidthMultiplier: 1,
      configuration: configuration
    )
    let candidate = ChalkPathWriting(
      preparation: preparation,
      style: style,
      colorPolicy: .source,
      animation: .write,
      motion: .uniform,
      progress: 1
    )
    let reference = ReferenceChalkPathView(
      plan: preparation.renderPlan,
      style: style,
      colorPolicy: .source,
      animation: .write,
      motion: .uniform,
      progress: 1
    )
    let size = CGSize(width: 640, height: 480)
    let candidateEvidence = try rasterEvidence(for: candidate, size: size)
    let referenceEvidence = try rasterEvidence(for: reference, size: size)
    let metrics = try assertPixelEquivalent(
      candidateEvidence,
      referenceEvidence,
      label: "isolated source-colored dot size=\(size)"
    )
    XCTAssertGreaterThan(candidateEvidence.nonTransparentPixelCount, 0)
    XCTAssertLessThanOrEqual(metrics.differentPixelCount, max(12, metrics.pixelCount / 400))
    XCTAssertLessThanOrEqual(metrics.maxChannelError, 24)
    XCTAssertLessThanOrEqual(metrics.maxAlphaError, 24)
    XCTAssertLessThanOrEqual(metrics.meanChannelAbsoluteError, 0.20)
    XCTAssertLessThanOrEqual(metrics.meanAlphaAbsoluteError, 0.20)
    XCTAssertLessThanOrEqual(
      abs(candidateEvidence.nonTransparentPixelCount - referenceEvidence.nonTransparentPixelCount),
      4
    )

    let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
    let centerPixel = candidateEvidence.pixel(at: center)
    let referenceCenterPixel = referenceEvidence.pixel(at: center)
    XCTAssertGreaterThanOrEqual(centerPixel.alpha, 240)
    XCTAssertGreaterThanOrEqual(referenceCenterPixel.alpha, 240)
    XCTAssertGreaterThan(centerPixel.red, centerPixel.blue + 80)
    XCTAssertGreaterThan(centerPixel.red, centerPixel.green + 80)
  }

  private func makePixelComparisonPathScene() throws -> ChalkPathScene {
    let pathColor = try ChalkColor(red: 0.12, green: 0.76, blue: 0.94)
    let dotColor = try ChalkColor(red: 0.98, green: 0.62, blue: 0.08)
    let pathStyle = try ChalkPathStrokeStyle(
      color: pathColor,
      width: 8,
      lineCap: .square,
      lineJoin: .miter,
      miterLimit: 10
    )
    let dotStyle = try ChalkPathStrokeStyle(
      color: dotColor,
      width: 10,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 4
    )
    let point: (Double, Double) -> ChalkPathPoint = { x, y in
      try! ChalkPathPoint(x: x, y: y)
    }
    let pathStroke = try ChalkPathStroke(
      id: "pixel-comparison-path",
      commands: [
        .move(to: point(10, 20)),
        .line(to: point(90, 20)),
        .line(to: point(62, 72)),
        .cubic(
          control1: point(42, 92),
          control2: point(78, 96),
          to: point(90, 82)
        ),
      ],
      style: pathStyle
    )
    let dotStroke = try ChalkPathStroke(
      id: "pixel-comparison-dot",
      commands: [.move(to: point(50, 90)), .line(to: point(50, 90))],
      style: dotStyle
    )
    return try ChalkPathScene(
      size: try WritingSize(width: 100, height: 100),
      strokes: [pathStroke, dotStroke],
      source: .custom(description: "pixel-comparison")
    )
  }

  private func plan(
    _ animation: ChalkWritingAnimation,
    progress: Double,
    timings: [WritingStrokeTiming],
    motion: ChalkWritingMotionStyle = .uniform,
    seed: UInt64 = 0,
    duration: Double? = nil
  ) -> ChalkWritingFramePlan {
    ChalkWritingFramePlan(
      animation: animation,
      progress: progress,
      duration: duration ?? self.duration,
      timings: timings,
      motion: motion,
      seed: seed
    )
  }

  private func makeTimings(_ ranges: [(Double, Double)]) throws -> [WritingStrokeTiming] {
    try ranges.enumerated().map { index, range in
      try WritingStrokeTiming(
        layerIndex: index,
        glyphIndex: 0,
        strokeIndex: index,
        strokeID: "stroke-\(index)",
        startTime: range.0,
        endTime: range.1
      )
    }
  }

  private func makeTimings(
    count: Int,
    strokeDuration: Double = 1,
    gap: Double = 0
  ) throws -> [WritingStrokeTiming] {
    try (0..<count).map { index in
      let start = Double(index) * (strokeDuration + gap)
      return try WritingStrokeTiming(
        layerIndex: index,
        glyphIndex: 0,
        strokeIndex: index,
        strokeID: "stroke-\(index)",
        startTime: start,
        endTime: start + strokeDuration
      )
    }
  }

  private enum Visibility: Equatable {
    case hidden
    case full
    case partial(Double)
  }

  private func visibility(
    of frame: ChalkWritingFramePlan,
    index: Int,
    count: Int
  ) -> Visibility {
    if let partial = frame.partialStroke, partial.index == index {
      if frame.isPrefix {
        if partial.fraction <= 0 { return .hidden }
        if partial.fraction >= 1 { return .full }
      } else {
        if partial.fraction >= 1 { return .hidden }
        if partial.fraction <= 0 { return .full }
      }
      return .partial(partial.fraction)
    }
    if frame.fullRange.contains(index) { return .full }
    XCTAssertTrue(frame.hiddenRange.contains(index) || index >= count)
    return .hidden
  }

  private func visibility(
    of slice: ChalkWritingStrokeSlice,
    animation: ChalkWritingAnimation
  ) -> Visibility {
    switch slice {
    case .prefix(let fraction):
      if fraction <= 0 { return .hidden }
      if fraction >= 1 { return .full }
      return .partial(fraction)
    case .suffix(let fraction):
      if animation != .eraseForward {
        XCTFail("reference prefix/suffix mismatch for \(animation)")
      }
      if fraction >= 1 { return .hidden }
      if fraction <= 0 { return .full }
      return .partial(fraction)
    }
  }

  private struct RasterEvidence {
    let bounds: CGRect
    let nonTransparentPixelCount: Int
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func pixel(at point: CGPoint) -> RasterPixel {
      let x = min(max(Int(point.x.rounded()), 0), width - 1)
      let y = min(max(Int(point.y.rounded()), 0), height - 1)
      let offset = (y * width + x) * 4
      return RasterPixel(
        red: rgba[offset],
        green: rgba[offset + 1],
        blue: rgba[offset + 2],
        alpha: rgba[offset + 3]
      )
    }
  }

  private struct RasterPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
  }

  private struct PixelMetrics {
    let pixelCount: Int
    let differentPixelCount: Int
    let maxChannelError: Int
    let maxAlphaError: Int
    let meanChannelAbsoluteError: Double
    let meanAlphaAbsoluteError: Double
  }

  private enum PixelComparisonError: Error {
    case dimensionMismatch
  }

  private func rasterEvidence<V: View>(for view: V, size: CGSize) throws -> RasterEvidence {
    let renderer = ImageRenderer(
      content: view
        .frame(width: size.width, height: size.height)
        .background(Color.clear)
    )
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage in this environment")
    }
    return try evidence(for: image)
  }

  private func evidence(for image: CGImage) throws -> RasterEvidence {
    let width = image.width
    let height = image.height
    let rgba = try normalizedRGBA(for: image)

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    var count = 0
    for y in 0..<height {
      for x in 0..<width {
        let alpha = rgba[(y * width + x) * 4 + 3]
        guard alpha > 0 else { continue }
        count += 1
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard count > 0 else {
      throw XCTSkip("ImageRenderer produced an empty alpha channel")
    }
    return RasterEvidence(
      bounds: CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
      ),
      nonTransparentPixelCount: count,
      width: width,
      height: height,
      rgba: rgba
    )
  }

  private func normalizedRGBA(for image: CGImage) throws -> [UInt8] {
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else {
      throw XCTSkip("CoreGraphics could not create an sRGB RGBA comparison context")
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else {
      throw XCTSkip("CoreGraphics comparison context has no readable pixel data")
    }
    let pointer = data.assumingMemoryBound(to: UInt8.self)
    return Array(
      UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4)
    )
  }

  @discardableResult
  private func assertPixelEquivalent(
    _ candidate: RasterEvidence,
    _ reference: RasterEvidence,
    label: String
  ) throws -> PixelMetrics {
    guard candidate.width == reference.width, candidate.height == reference.height else {
      XCTFail("pixel dimensions differ for \(label)")
      throw PixelComparisonError.dimensionMismatch
    }
    var differentPixelCount = 0
    var maxChannelError = 0
    var maxAlphaError = 0
    var totalChannelError = 0
    var totalAlphaError = 0
    for pixelOffset in stride(from: 0, to: candidate.rgba.count, by: 4) {
      let candidateRed = Int(candidate.rgba[pixelOffset])
      let candidateGreen = Int(candidate.rgba[pixelOffset + 1])
      let candidateBlue = Int(candidate.rgba[pixelOffset + 2])
      let candidateAlpha = Int(candidate.rgba[pixelOffset + 3])
      let referenceRed = Int(reference.rgba[pixelOffset])
      let referenceGreen = Int(reference.rgba[pixelOffset + 1])
      let referenceBlue = Int(reference.rgba[pixelOffset + 2])
      let referenceAlpha = Int(reference.rgba[pixelOffset + 3])
      let redError = abs(candidateRed - referenceRed)
      let greenError = abs(candidateGreen - referenceGreen)
      let blueError = abs(candidateBlue - referenceBlue)
      let alphaError = abs(candidateAlpha - referenceAlpha)
      if redError > 0 || greenError > 0 || blueError > 0 || alphaError > 0 {
        differentPixelCount += 1
      }
      maxChannelError = max(maxChannelError, redError, greenError, blueError)
      maxAlphaError = max(maxAlphaError, alphaError)
      totalChannelError += redError + greenError + blueError
      totalAlphaError += alphaError
    }
    let pixelCount = candidate.width * candidate.height
    let metrics = PixelMetrics(
      pixelCount: pixelCount,
      differentPixelCount: differentPixelCount,
      maxChannelError: maxChannelError,
      maxAlphaError: maxAlphaError,
      meanChannelAbsoluteError: Double(totalChannelError) / Double(pixelCount * 3),
      meanAlphaAbsoluteError: Double(totalAlphaError) / Double(pixelCount)
    )
    print(
      "[pixel] \(label): different=\(metrics.differentPixelCount)/\(metrics.pixelCount) "
        + "maxRGB=\(metrics.maxChannelError) maxA=\(metrics.maxAlphaError) "
        + "meanRGB=\(metrics.meanChannelAbsoluteError) "
        + "meanA=\(metrics.meanAlphaAbsoluteError)"
    )
    return metrics
  }

  private func normalize(_ bounds: CGRect, in size: CGSize) -> CGRect {
    CGRect(
      x: bounds.minX / size.width,
      y: bounds.minY / size.height,
      width: bounds.width / size.width,
      height: bounds.height / size.height
    )
  }
}

/// Test-only pre-optimization renderer for semantic writing. It mirrors the
/// old per-stroke slice and transformed-path loop so the optimized Canvas can
/// be compared against actual pixels without retaining a production
/// implementation or API.
private struct ReferenceChalkWritingView: View {
  let plan: ChalkWritingRenderPlan
  let style: ChalkWritingStyle
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle
  let progress: Double

  var body: some View {
    Canvas { context, size in
      let sceneWidth = max(plan.sceneSize.width, 1)
      let sceneHeight = max(plan.sceneSize.height, 1)
      let widthScale = Double(size.width) / sceneWidth
      let heightScale = Double(size.height) / sceneHeight
      let scale = min(widthScale, heightScale)
      guard scale.isFinite, scale > 0 else { return }

      let offsetX = (Double(size.width) - sceneWidth * scale) * 0.5
      let offsetY = (Double(size.height) - sceneHeight * scale) * 0.5
      let transform = CGAffineTransform(
        a: CGFloat(scale), b: 0, c: 0, d: CGFloat(scale),
        tx: CGFloat(offsetX), ty: CGFloat(offsetY)
      )
      let color = style.color.swiftUIColor

      for renderStroke in plan.strokes {
        let slice = animation.strokeSlice(
          at: progress,
          duration: plan.duration,
          timing: renderStroke.timing,
          motion: motion,
          seed: style.configuration.seed
        )
        let lineWidth = max(
          0.5,
          renderStroke.averageWidth * style.lineWidthMultiplier * scale
        )

        let path: Path?
        let rendersAsDot: Bool
        switch slice {
        case .prefix(let fraction):
          guard fraction > 0 else { continue }
          rendersAsDot = renderStroke.rendersAsDot(at: fraction)
          path = fraction >= 1
            ? renderStroke.fullPath
            : try? renderStroke.path(upTo: fraction)
        case .suffix(let fraction):
          guard fraction < 1 else { continue }
          rendersAsDot = renderStroke.points.count == 1 || renderStroke.length <= 0
          path = fraction <= 0
            ? renderStroke.fullPath
            : try? renderStroke.path(from: fraction)
        }

        if rendersAsDot {
          let point = CGPoint(
            x: renderStroke.points[0].x * scale + offsetX,
            y: renderStroke.points[0].y * scale + offsetY
          )
          let radius = CGFloat(lineWidth * 0.5)
          context.fill(
            Path(
              ellipseIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
              )
            ),
            with: .color(color)
          )
          continue
        }

        guard let path else { continue }
        context.stroke(
          path.applying(transform),
          with: .color(color),
          style: StrokeStyle(
            lineWidth: CGFloat(lineWidth),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
    .chalkEffect(style.configuration)
    .accessibilityLabel("Chalk writing playback")
  }
}

/// Test-only pre-optimization renderer. It mirrors the old per-stroke
/// transform/slice path so raster bounds remain an observable behavior
/// oracle without keeping a production API or implementation around.
private struct ReferenceChalkPathView: View {
  let plan: ChalkPathRenderPlan
  let style: ChalkWritingStyle
  let colorPolicy: ChalkPathColorPolicy
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle
  let progress: Double

  var body: some View {
    Canvas { context, size in
      let sceneWidth = max(plan.sceneSize.width, 1)
      let sceneHeight = max(plan.sceneSize.height, 1)
      let widthScale = Double(size.width) / sceneWidth
      let heightScale = Double(size.height) / sceneHeight
      let scale = min(widthScale, heightScale)
      guard scale.isFinite, scale > 0 else { return }

      let offsetX = (Double(size.width) - sceneWidth * scale) * 0.5
      let offsetY = (Double(size.height) - sceneHeight * scale) * 0.5
      let transform = CGAffineTransform(
        a: CGFloat(scale), b: 0, c: 0, d: CGFloat(scale),
        tx: CGFloat(offsetX), ty: CGFloat(offsetY)
      )
      for renderStroke in plan.strokes {
        let slice = animation.strokeSlice(
          at: progress,
          duration: plan.duration,
          timing: renderStroke.timing,
          motion: motion,
          seed: style.configuration.seed
        )
        let strokeColor = resolvedColor(for: renderStroke)
        let lineWidth = max(
          0.5,
          renderStroke.style.width * style.lineWidthMultiplier * scale
        )
        let path: Path?
        let rendersAsDot: Bool
        switch slice {
        case .prefix(let fraction):
          guard fraction > 0 else { continue }
          rendersAsDot = renderStroke.rendersAsDot
          path = fraction >= 1 ? renderStroke.fullPath : renderStroke.path(upTo: fraction)
        case .suffix(let fraction):
          guard fraction < 1 else { continue }
          rendersAsDot = renderStroke.rendersAsDot
          path = fraction <= 0 ? renderStroke.fullPath : renderStroke.path(from: fraction)
        }

        if rendersAsDot {
          let point = CGPoint(
            x: renderStroke.startPoint.x * scale + offsetX,
            y: renderStroke.startPoint.y * scale + offsetY
          )
          let radius = CGFloat(lineWidth * 0.5)
          context.fill(
            Path(
              ellipseIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
              )
            ),
            with: .color(strokeColor)
          )
          continue
        }

        guard let path else { continue }
        context.stroke(
          path.applying(transform),
          with: .color(strokeColor),
          style: StrokeStyle(
            lineWidth: CGFloat(lineWidth),
            lineCap: lineCap(for: renderStroke.style.lineCap),
            lineJoin: lineJoin(for: renderStroke.style.lineJoin),
            miterLimit: CGFloat(renderStroke.style.miterLimit)
          )
        )
      }
    }
    .chalkEffect(style.configuration)
  }

  private func resolvedColor(for stroke: ChalkPathRenderPlan.Stroke) -> Color {
    switch colorPolicy {
    case .style:
      return style.color.swiftUIColor
    case .source:
      return (stroke.style.color ?? style.color).swiftUIColor
    }
  }

  private func lineCap(for value: ChalkPathLineCap) -> CGLineCap {
    switch value {
    case .butt: return .butt
    case .round: return .round
    case .square: return .square
    }
  }

  private func lineJoin(for value: ChalkPathLineJoin) -> CGLineJoin {
    switch value {
    case .miter: return .miter
    case .round: return .round
    case .bevel: return .bevel
    }
  }
}
