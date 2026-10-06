# 분필 기본값·성능 검증 — 2026-10-06

[사용 안내](README.md) · [측정 코드](../Examples/LiveTextDemo/DemoBenchmark.swift)

마른 분필을 새 기본값으로 적용했고 가는 분필은 명시적으로 선택할 수 있다.
기존 `.classic`/`.fineLine` preset과 저장된 style은 유지한다. style 필드가 없는 구형 JSON도 이전처럼 fineLine으로 해석한다.
검증 대상은 기반 커밋 `ff4a269047355ec926a06aad7e166ed5f1915659`에 이번 구현 변경을 적용한 로컬 working tree다.
분석·로컬 수정·검증 완료를 기록하며 배포나 실제 iOS 기기 검증 완료를 뜻하지 않는다.

## 관측과 수정

1. 같은 preparation으로 공개 `ChalkWritingText(preparation: ...)`를 재생성할 때 접촉 geometry를 다시 생성했다.
   벤치마크는 외부에서 진행률을 바꿔 View를 반복 생성하는 경로다. 내장 timeline은 기존에도 준비된 plan을 사용했다.
   `ChalkWritingPreparationCache`에 재질·선폭 기준 마지막 결과 하나를 보관한다.
   문서별 cache 수명을 사용하고 NSLock으로 동시 접근과 eviction을 보호한다. 오류도 같은 기준으로 유지한다.
   색은 geometry key에 포함하지 않으며 실제 색은 paint에서 적용한다.
2. 보드 질감 shading을 각 접촉의 drawLayer에서 반복 해석했다.
   GraphicsContext의 동일한 document-space shading과 clip path를 프레임당 한 번 준비해 재사용한다.
   접촉마다 적용되는 opacity와 합성 순서는 유지한다.
3. 접촉별 작은 clipping 영역은 측정에서 더 느렸다. 해당 변경은 제거했다.
   픽셀 보존과 실제 감소가 확인된 변경만 남겼다.

Time Profiler의 수정 전 샘플에서 `ChalkPreparedContactPlan.plan`과 `ChalkWritingText`의 접촉 준비가 반복 관측됐다.
그리기에서는 `GraphicsContext.drawLayer`, shading/fill과 RenderBox/AGX 명령 처리가 주요 경로였다.
따라서 준비 재사용과 shading 해석 중복 제거를 먼저 적용했다.

## 동일 조건 측정

환경: MacBook Pro arm64, macOS 27.0.1, Xcode 27.0, Swift 6.4, **Release**.
실제 SwiftUI ImageRenderer, 680×240pt, scale 2, 각 workload warmup 10회 + 측정 60회.
일반 문장 37획, 같은 문장 6줄은 222획이다. 진행률은 0.1~1.0을 반복한다.
bitmap data materialization까지 측정하며 PNG 인코딩과 디스크 I/O는 제외한다.
`View 생성`은 같은 preparation을 재사용하는 공개 initializer와 frame 구성 시간이다.
JSON의 `semanticPreparationMS`는 실제로 `DemoContent` 전체 생성 시간이며 semantic preparation과 inline 문서 준비·배치를 함께 포함한다.
이 값은 workload당 초기 1회 측정으로 warmup 후 median 비교 대상에 포함하지 않는다.
`median`과 `p95`는 측정 코드가 정렬된 60개 표본의 인덱스로 계산한 JSON 필드 값이다.

| 마른 분필 측정 | 수정 전 median | 수정 후 median |
|---|---:|---:|
| 일반 문장 View 생성 | 0.1615ms | 0.0018ms |
| 일반 문장 bitmap | 3.594ms | 2.916ms |
| 6줄 문단 View 생성 | 0.9819ms | 0.0067ms |
| 6줄 문단 bitmap | 16.678ms | 14.640ms |

6줄 문단 bitmap의 p95는 30.728→25.750ms다. 이 값은 동일 로컬 workload의 관측치이며
디스플레이 FPS·GPU frame deadline·모든 기기의 성능을 보증하지 않는다.
가장 큰 감소는 반복 준비 비용이며, 남은 비용은 실제 픽셀 합성과 데이터 materialization이다.

실행과 원시 자료:

```sh
./script/build_and_run.sh --benchmark .build/demo-benchmark/current
```

- 저장소에 포함된 측정 JSON: [수정 전](evidence/benchmark-before-2026-10-06.json), [수정 후](evidence/benchmark-after-2026-10-06.json).
- Time Profiler 자료: `.build/demo-benchmark/before/cpu.trace`, `.build/demo-benchmark/before/paragraph-cpu.trace`, `.build/demo-benchmark/after/cpu.trace`.
- before JSON SHA-256: `fa60eed4773e182b833437e120304a2218f252e1dc1b35ec81bc8cebf2108175`.
- after JSON SHA-256: `03c21113a72741c2863550c58e35eb98d87f4e732eab74b9c5db48fec3cf4814`.
- [DemoBenchmark.swift](../Examples/LiveTextDemo/DemoBenchmark.swift): 현재 버전의 재현 가능한 측정 코드.
- 방법 참고: [Apple SwiftUI 성능 분석](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance),
  [GraphicsContext](https://developer.apple.com/documentation/swiftui/graphicscontext)

측정 JSON은 위 evidence 경로에 보존했다. 대용량 trace는 로컬 자료이며 Git에 포함하지 않는다. 스크립트의 benchmark 모드는 JSON만 생성하며 trace를 자동 생성하지 않는다.
현재 결과를 새 디렉터리에 측정할 수 있지만, 이전 JSON을 덮어쓰거나 현재 코드로 before 결과를 재생성하면 같은 역사적 비교가 되지 않는다.

## 출력·안전성 검증

| 기준 | 결과·방법 | 범위 |
|---|---|---|
| 분필 회귀 | PASS / TEST | XCTest 19개와 Swift Testing 8개 함수의 19개 입력 시나리오 |
| cache 동시 접근 | PASS / TEST | Thread Sanitizer에서 24개 동시 작업의 preparation 재사용, 순차 style 변경, 구형 JSON·기본값 검사 |
| 출력 보존 | PASS / RUNTIME | 마른/가는 분필 × 세 텍스처, 1584×3866 갤러리가 성능 변경 전후 RGBA byte-identical |
| macOS | PASS / BUILD·RUNTIME | Debug/Release 빌드, 실제 PNG export, 앱의 입력 오류·복구·재생 완료·accessibility label 확인 |
| iOS | PASS / BUILD | iOS Simulator SDK 대상으로 `LiveTextWritingUI`와 의존 target compile; 앱 실행 아님 |
| 실제 iOS 기기·VoiceOver | NOT_RUN | 실제 기기 FPS·배터리·GPU frame time·VoiceOver 전체 동선 |

실행한 검증 명령은 다음과 같다. 테스트 scratch와 로그는 당시 로컬 자료이므로 현재 checkout의 위치를 고정 계약으로 삼지 않는다.

```sh
swift test --scratch-path /tmp/livetext-compare-20261006.QLof2A/implementation-build
swift test --scratch-path /tmp/livetext-compare-20261006.QLof2A/tsan-build --sanitize thread --filter ChalkDefaultsAndCacheTests
swift build --product LiveTextWritingUI --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios16.0-simulator --scratch-path /tmp/livetext-compare-20261006.QLof2A/ios-build
./script/build_and_run.sh --export
./script/build_and_run.sh --verify
```

## 미확인 범위

실제 iOS 기기의 FPS·배터리·GPU frame time·VoiceOver 전체 동선은 측정하지 않았다.
획당 8,192 상한과 cache 1-entry 정책은 유지하지만 문서 전체의 aggregate contact memory budget은 별도 계약이다.
큰 custom preparation은 호출자가 입력 규모를 관리해야 하며, 이를 작은 일반 문장 측정으로 안전하다고 주장하지 않는다.
새 aggregate memory policy나 실제 기기 성능 목표는 이번에 구현·검증된 계약에 포함하지 않는다.
