# LiveText

텍스트·이미지·SVG를 배치하고 SwiftUI와 Canvas로 표현하는 Swift 패키지입니다.
분필 writing과 iOS particle 효과를 별도 제품으로 사용할 수 있습니다.

- Swift 6.0 이상, iOS 16 이상, macOS 13 이상
- 외부 SwiftPM 의존성 없음
- 자세한 사용법과 제품 목록: [사용 안내](docs/README.md)

## Swift Package Manager

Xcode에서 `https://github.com/axiom-orient/LiveText.git`을 패키지로 추가합니다.
개선 내용은 `0.2.0-rc.1` 검토용 버전으로 제공합니다. 현재 알려진 렌더링 검사
실패와 검증 범위는 [배포 검토 결과](docs/RELEASE_READINESS.md)를 확인하세요.
이 변경은 기존 `0.1.0` 태그에 포함되지 않습니다.

```swift
.package(url: "https://github.com/axiom-orient/LiveText.git", exact: "0.2.0-rc.1")
```

일반 Apple 화면에는 `LiveTextApple`과 `LiveTextWritingUI`, 독립 분필 표현에는
`ChalkLineEffects` 제품을 연결합니다. iOS 예제는
[LiveTextSample](Samples/LiveTextSample/LiveTextSample.xcodeproj), macOS 예제는
`./script/build_and_run.sh`로 실행합니다.

Copyright © Axient Inc.

저장소 전체에 별도의 MIT 사용 허가를 부여하지 않습니다. 외부에서 가져온 코드의 필수 고지는
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
