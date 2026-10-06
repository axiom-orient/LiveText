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

`LiveTextDemo`는 package 내부 target을 사용하는 macOS 예제입니다.
외부 앱에서 일반 문서를 그릴 때는 공개 product인 `LiveTextWritingUI`를 사용합니다.
[DemoContent.swift](../Examples/LiveTextDemo/DemoContent.swift)가 실제 준비→레이아웃→렌더링 호출 예제입니다.
`ChalkLineEffects`와 `LiveTextChalkRendering`은 별도 library product가 아닌 내부 target입니다.
데모의 semantic writing 코드를 외부 앱의 공개 product 예제로 그대로 해석하지 마세요.

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

| Product | 역할 |
|---|---|
| LiveText | Core + Layout + renderer-neutral Effects |
| LiveTextSVG | bounded SVG import |
| LiveTextApple | Apple rendering facade |
| LiveTextWritingUI | SwiftUI/Canvas writing composition |
| DustKit | terminal raster particle effect |
| LiveTextPresentation | LiveText snapshot → Dust composition |
| LiveTextDemo | macOS 실행·PNG 출력 예제 |

## 검사와 보존 계약

```sh
swift build
swift test
```

분필 테스트는 macOS/Xcode에서 실제 bitmap과 public semantic View를 검사합니다.
Linux에서는 Apple target/test와 데모가 제외됩니다.

준비 실패·unsupported text·자원 초과는 오류로 드러납니다.
접촉 분필의 획당 상한은 8,192개이며, 기존 spacing 기준으로 허용하던 길이를 유지합니다.
재질의 더 촘촘한 접촉은 이 상한 안에서 균일한 arc grid를 사용합니다. 임의로 획 끝을 버리지 않습니다.
stroke ID·seed가 같은 접촉은 문서 내 순서를 바꿔도 유지되며, 선택한 텍스처는 실제 pigment coverage에 반영됩니다.
마른 분필은 번들 tip의 alpha 점유율을 반영해 빈 brush slot이 농도를 과도하게 낮추지 않도록 합니다.
`ChalkWritingText(preparation: ...)`에 같은 preparation을 재사용하면 마지막 재질·선폭의 접촉 계획 하나를 lock으로 보호해 재사용합니다.
같은 재질·선폭에서 색과 진행률을 바꾸면 재료 geometry를 다시 준비하지 않습니다.
텍스트를 직접 받는 initializer는 호출마다 새 preparation을 만듭니다. 새 문서에는 새 preparation을 만드세요.
새 configuration/default는 마른 분필이며, 저장된 명시적 재질과 style 없는 구형 JSON의 가는 분필은 보존합니다.

분필 geometry 개선은 `ChalkWritingText`의 semantic contact 경로에 적용됩니다.
정확한 SVG path와 일반 inline renderer는 기존 mask 경로를 사용합니다.
append/cancellation와 Dust의 구현은 이번 변경에서 수정하지 않았습니다.
semantic Latin/Hangul catalog는 특정 사람의 실제 필적 복원이 아닙니다.
Bundle resources와 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 함께 배포해야 합니다.

실제 iOS/Metal·VoiceOver·디스플레이 FPS·전체 plan의 aggregate memory limit은 별도 검증 대상입니다.

## 문서와 검증 범위

이 안내는 현재 실행·API·입출력 계약을 설명하고, [PERFORMANCE.md](PERFORMANCE.md)는
2026-10-06 검증 조건·관측값·미확인 범위를 기록합니다. 빌드 성공은 실제 기기 FPS나 모든 기능의 runtime 검증을 뜻하지 않습니다.

`.build/`와 `dist/`는 생성물로 Git에서 제외됩니다. PNG와 benchmark JSON·trace는 이 로컬 checkout의 검증 자료이며
다른 checkout이나 `swift package clean` 이후에 존재한다고 보장하지 않습니다. 위 export/benchmark 명령으로 현재 출력을 다시 만들 수 있습니다.
성능 비교에 사용한 두 측정 JSON은 [docs/evidence](evidence)에 별도로 보존했습니다.
