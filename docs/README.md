# LiveText 사용 안내

[성능 분석·검증 기록](PERFORMANCE.md) · [저작물 출처](../THIRD_PARTY_NOTICES.md)

텍스트·벡터·이미지를 준비하고 배치한 뒤 SwiftUI와 Canvas로 표현하는 Swift 라이브러리입니다.
문서 의미·레이아웃·hit geometry는 core/layout이 소유하고, 분필과 Dust는 표현 계층입니다.

Swift tools/language 6.0 이상, iOS 16 이상, macOS 13 이상을 사용합니다. 외부 패키지 의존성은 없습니다.

## 실제 실행과 출력

아래 명령은 `LiveText` 프로젝트 루트에서 macOS/Xcode 환경으로 실행합니다.
실행 스크립트는 기존 `LiveTextDemo` 프로세스를 종료하고 빌드한 뒤 `dist/LiveTextDemo.app`을 만듭니다.

```sh
./script/build_and_run.sh
```

텍스트·글자 크기·분필·텍스처를 선택하고 **적용**을 누릅니다. **재생**은 실제 semantic stroke timeline을 실행합니다.
기본 재질은 **마른 분필**입니다. 가는 분필과 다른 재질은 선택해서 사용합니다.
슬라이더로 진행률을 조절하고 쓰기·앞부터 지우기·뒤부터 지우기를 확인할 수 있습니다.
재생 중에는 진행률 슬라이더와 **PNG 저장**이 비활성화됩니다. **처음으로**는 진행률을 0으로 되돌립니다.
**PNG 저장**은 현재 출력 상태를 2배 해상도로 저장합니다. 아래 문서 영역은 `LiveTextWritingRenderer`의 완성본입니다.

```sh
./script/build_and_run.sh --export
```

`.build/demo-output/`에 실제 SwiftUI `ImageRenderer`로 그린 분필/텍스처 갤러리,
25개 쓰기 프레임, 일반 inline 문서 출력, export 시간 JSON을 만듭니다.
export 시간에는 PNG 인코딩과 디스크 I/O가 포함되며 화면 FPS가 아닙니다.
별도 출력 경로는 `--export /absolute/output/path`로 지정합니다.

```sh
./script/build_and_run.sh --benchmark
```

Release 빌드로 일반 문장과 6줄 문단을 각각 60번 측정합니다(별도 warmup 10회).
준비·View 생성·bitmap 생성 시간을 분리하고 `.build/demo-benchmark/benchmark.json`에 기록합니다.
bitmap 생성에는 실제 픽셀 데이터 materialization을 포함하고 PNG·디스크 I/O는 제외합니다.
[성능 분석과 검증 결과](PERFORMANCE.md)를 확인하세요.

`LiveTextDemo`는 macOS 예제입니다. 외부 앱에서 일반 문서를 그릴 때는
`LiveTextApple`과 `LiveTextWritingUI`를 사용하고, 독립적인 획 표현은 `ChalkLineEffects`를 사용합니다.
[DemoContent.swift](../Examples/LiveTextDemo/DemoContent.swift)가 실제 준비→레이아웃→렌더링 호출 예제입니다.
`LiveTextChalkRendering`은 package 내부 target입니다.

iOS에서는 [LiveTextSample.xcodeproj](../Samples/LiveTextSample/LiveTextSample.xcodeproj)를 열고
`LiveTextSample` scheme을 실행합니다. 이 샘플은 package를 상대 경로로 참조합니다.

## 기본 재질과 선택

새 `WritingChalkConfiguration()`과 `.default`, `ChalkWritingStyle.chalk`,
`InlineWritingConfiguration.chalk`는 마른 분필을 사용합니다.
명시적으로 선택한 `.classic`과 `.fineLine` preset, 저장된 style은 유지합니다.
style 필드가 없는 구형 configuration JSON은 가는 분필로 해석합니다.

데모에서는 분필 선택 후 **적용**을 누릅니다. 공개 문서 renderer에서는 다음처럼 선택합니다.

```swift
import LiveTextApple
import LiveTextWritingUI

let defaultMaterial = InlineWritingConfiguration.chalk
let fineLineMaterial = InlineWritingConfiguration(
  effect: .chalk(try WritingChalkConfiguration(style: .fineLine))
)
```

이 예시는 재질 선택이며, 준비된 content와 viewport는
[InlineLiveTextScene](../Sources/LiveTextWritingUI/InlineLiveTextScene.swift)과
[LiveTextWritingRenderer](../Sources/LiveTextWritingUI/LiveTextWritingRenderer.swift)의 계약을 따릅니다.

## 제품

SVG import는 제한된 정적 도형을 검증해 변환합니다. `LiveTextSVGImporter`는 inline
coverage·trajectory를 만들고, `LiveTextSVGArtworkImporter`는 여러 색의 정적 path를
만듭니다. DTD·외부 참조·script와 지원하지 않는 속성은 오류로 거부합니다.
Artwork의 부분적인 container opacity와 fill+stroke 전체 opacity는 현재 평면
출력 모델이 정확히 표현할 수 없어 오류를 반환합니다. `fill-opacity`와
`stroke-opacity`, 단일 paint의 opacity는 지원합니다. 이 제한은 각 paint의 alpha를
곱하는 것과 그룹 전체를 합성하는 것이 다르다는 [SVG 규칙](https://www.w3.org/TR/SVG2/render.html#ObjectAndGroupOpacityProperties)에 따릅니다.

| Product | 역할 |
|---|---|
| LiveText | Core + Layout + renderer-neutral Effects |
| LiveTextCore | 텍스트 분석·측정·줄바꿈 |
| LiveTextLayout | inline 문서·레이아웃·interaction |
| LiveTextEffects | renderer-neutral 재질·모션 |
| LiveTextSVG | bounded SVG import |
| LiveTextApple | Apple rendering facade |
| LiveTextAppleRendering | Apple rendering adapters |
| LiveTextSwiftUI | SwiftUI renderer |
| LiveTextCanvas | Canvas renderer |
| LiveTextWritingUI | SwiftUI/Canvas writing composition |
| ChalkLineEffects | 독립 분필 writing·surface 표현 |
| DustKit | terminal raster particle effect |
| LiveTextPresentation | LiveText snapshot → Dust composition |
| LiveTextDemo | macOS 실행·PNG 출력 예제 |

## 검사와 보존 계약

```sh
swift build
swift test
swift test --package-path Tests/Fixtures/ProductConsumer
```

분필 테스트는 macOS/Xcode에서 실제 bitmap과 public semantic View를 검사합니다.
Linux에서는 Apple target/test와 데모가 제외됩니다.
`LiveTextLayoutContractTests`는 준비 데이터의 한도·식별자·복원, 폭과 flow 배치,
continuation, append replay·취소, hit·selection의 회귀를 검사합니다.
`LiveTextEffectsTests`는 재질 복원, 모션의 시작·종료와 Reduce Motion, geometry의
유한성·분배 상한을 검사합니다.
마지막 명령은 별도의 Apple-platform 소비자 패키지가 13개 공개 library product를
직접 연결하고 import하며 inline 및 magazine scene을 생성하는지 확인합니다. iOS에서는
`Tests/Fixtures/ProductConsumer`에서 다음 명령으로 이 소비자 테스트를 실행할 수 있습니다.

```sh
xcodebuild -scheme LiveTextProductConsumer -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

저장소 루트의 iOS 전체 패키지 테스트는 다음처럼 macOS 전용 데모만 명시적으로 제외합니다.
이 환경 변수를 설정하지 않으면 macOS 데모 product와 실행 스크립트는 그대로 제공됩니다.

```sh
LIVETEXT_EXCLUDE_MACOS_DEMO=1 xcodebuild -scheme LiveText-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

기존 `InlineFlowRegion(..., layoutStyle: .inline)`과 `.magazine(style)` 호출은
유지됩니다. `.inline`은 기본 flow와 같고, `.magazine(style)`은 magazine 전용
`magazineStyle:` initializer와 동일한 검증과 결과를 사용합니다.
`InlineLiveTextLayoutConfiguration`의 기본값은 기존 공개 버전과 동일한 빈 magazine
정책입니다. 이전 로컬 복사본의 inline 동작이 필요하면 `layoutStyle: .inline`을
명시하세요. Inline 정책은 magazine의 최소 텍스트 폭 검사를 적용하지 않습니다.

폭만 지정하는 `InlineLayoutEngine.layout(prepared:width:)`와 width-only streaming은
기본 inline flow를 사용합니다. Magazine의 최소 텍스트 폭은 명시적으로 선택한
magazine flow에만 적용됩니다. Prepared 데이터의 정책 정보가 없는 경우에는 두
기본 정책의 digest 중 하나와 일치하고 실제 내용·수량 검증까지 통과한 데이터만
복원합니다. 사용자 정의 한도가 빠진 데이터는 추측해서 복원하지 않습니다.
이전 로컬 버전과 공개 버전에서 사용한 두 digest 구분 문자열을 검증하며, 복원한
데이터의 revision은 기존 continuation과 연결될 수 있도록 보존합니다. 새로 만드는
데이터는 현재 공개 버전의 구분 문자열을 계속 사용합니다.
복원 대상도 현재 source mapping·줄바꿈 메타데이터 검증을 통과해야 합니다.
이 규칙과 맞지 않는 예전 prepared cache는 오류를 반환하므로, host가 원본
`InlineDocument`에서 다시 준비해야 합니다.

준비 실패·unsupported text·자원 초과는 오류로 드러납니다.
접촉 분필의 획당 상한은 8,192개이며, 기존 spacing 기준으로 허용하던 길이를 유지합니다.
재질의 더 촘촘한 접촉은 이 상한 안에서 균일한 arc grid를 사용합니다. 임의로 획 끝을 버리지 않습니다.
stroke ID·seed가 같은 접촉은 문서 내 순서를 바꿔도 유지되며, 선택한 텍스처는 실제 pigment coverage에 반영됩니다.
마른 분필은 번들 tip의 alpha 점유율을 반영해 빈 brush slot이 농도를 과도하게 낮추지 않도록 합니다.
`ChalkWritingText(preparation: ...)`에 같은 preparation을 재사용하면 마지막 재질·선폭의 접촉 계획 하나를 lock으로 보호해 재사용합니다.
같은 재질·선폭에서 색과 진행률을 바꾸면 재료 geometry를 다시 준비하지 않습니다.
일반 재질과 색연필의 문서 전체 예산은 양수 요청에만 분배합니다. 빈 대상의
개수나 위치가 다른 대상의 효과를 사라지게 하거나 예산을 소모하지 않습니다.
색연필 stroke의 부분 샘플링은 전체 계획 생성과 같은 안전한 보간을 사용해,
유한한 극단 좌표와 선폭에서도 overflow로 중단되지 않도록 합니다.
텍스트를 직접 받는 initializer는 호출마다 새 preparation을 만듭니다. 새 문서에는 새 preparation을 만드세요.
새 configuration/default는 마른 분필이며, 저장된 명시적 재질과 style 없는 구형 JSON의 가는 분필은 보존합니다.

분필 geometry 개선은 `ChalkWritingText`의 semantic contact 경로에 적용됩니다.
정확한 SVG path와 일반 inline renderer는 기존 mask 경로를 사용합니다.
append/cancellation와 Dust의 구현은 이번 변경에서 수정하지 않았습니다.
semantic Latin/Hangul catalog는 특정 사람의 실제 필적 복원이 아닙니다.
Bundle resources와 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 함께 배포해야 합니다.

실제 iOS/Metal·VoiceOver·디스플레이 FPS·전체 plan의 aggregate memory limit은 별도 검증 대상입니다.

2026-11-06 iOS 26.5 Simulator에서 위 전체 패키지 테스트를 실행하면 분필 접촉 raster의 진행률 전후 비교 한 건이 실패합니다. 이전 영역의 네 픽셀에서 8-bit 채널 값이 각각 1만큼 달랐으며, 원인은 아직 확정되지 않았습니다. macOS 27.0.1의 별도 로컬 테스트에서는 standalone View와 Canvas의 분필 가장자리 픽셀 비교도 허용 범위를 벗어났습니다. 이 두 결과를 테스트 성공으로 처리하지 않습니다.

## 문서와 검증 범위

이 안내는 현재 실행·API·입출력 계약을 설명하고, [PERFORMANCE.md](PERFORMANCE.md)는
2026-10-06 검증 조건·관측값·미확인 범위를 기록합니다. 빌드 성공은 실제 기기 FPS나 모든 기능의 runtime 검증을 뜻하지 않습니다.

`.build/`와 `dist/`는 생성물로 Git에서 제외됩니다. PNG와 benchmark JSON·trace는 이 로컬 checkout의 검증 자료이며
다른 checkout이나 `swift package clean` 이후에 존재한다고 보장하지 않습니다. 위 export/benchmark 명령으로 현재 출력을 다시 만들 수 있습니다.
성능 비교에 사용한 두 측정 JSON은 [docs/evidence](evidence)에 별도로 보존했습니다.
