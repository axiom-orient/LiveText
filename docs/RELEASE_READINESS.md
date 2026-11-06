# 공개 배포 검토 — 0.2.0

2026-11-06 기준 안정판 출시 검증을 통과했습니다. `0.2.0-rc.1`에서 남았던
macOS 두 건과 iOS 한 건의 실패를 해결했습니다. 기존 assertion의 허용 범위는
유지했으며 검사 제외나 재시도로 성공을 만들지 않았습니다.

## 원인과 수정

| 실패 | 확인한 원인·경계 | 수정과 회귀 확인 |
|---|---|---|
| macOS View/painter 분필 가장자리 | painter가 먼지 투명도를 개별 작업에 적용했고 텍스처 범위를 원본 도형 경계로 제한해, 합친 그룹과 blur 영역을 처리하는 View 경로와 달랐음 | 투명도는 완성된 그룹에 적용하고 텍스처는 유한한 visible clip 영역에 적용. 외곽 alpha 합 차이 305 → 134로 기존 192·10% 기준 통과 |
| macOS 같은 설정의 반복 출력 | `ImageRenderer.cgImage`의 반복 출력에서 실제 bitmap 차이를 재현. 명시적인 RGBA 컨텍스트에 그린 출력은 일치했음 | 공개 snapshot이 자체 sRGB 8-bit premultiplied RGBA 컨텍스트를 소유하고 `ImageRenderer.render`로 한 번 출력. 첫 호출부터 8회 반복을 1·2·3배에서 byte 단위로 비교해 통과 |
| iOS 진행률 전후 기존 영역 | 동일한 준비 데이터의 prefix 0.35/0.75를 편의 출력으로 내보내면 기존 네 픽셀에서 채널별 1/255 차이가 발생. 준비된 획·seed와 분리된 출력 경계에서 재현됨 | 실제 공개 snapshot 출력으로 비교. 기존 영역의 모든 RGBA 값이 일치하며 획 geometry·선택 규칙은 유지 |

Apple의 비공개 렌더러 내부 구현은 원인으로 단정하지 않습니다. 위 비교는 같은
입력의 출력 경로를 바꿔 확인한 실행 근거입니다. 픽셀 재현성 검증 범위는 공개
snapshot API의 sRGB 8-bit 출력입니다.

이 출력 경로를 적용하면서 filtered Canvas의 `View.mask`가 본문을 비우는 경우도
검출했습니다. mask의 alpha 곱셈을 독립적인 RGBA 그룹 합성으로 구현해 해결했습니다.
원래 View 구성은 유지하며, 첫 프레임부터 본문 농도가 남는 검사도 추가했습니다.
[그룹 그리기](https://developer.apple.com/documentation/swiftui/graphicscontext/drawlayer(content:))와
[직접 CGContext 출력](https://developer.apple.com/documentation/swiftui/imagerenderer/render(rasterizationscale:renderer:))을 사용합니다.

Snapshot의 사전 크기·자원 한도 검증은 유지합니다. 0.5·1·2·3배에서 출력 크기,
위·아래 원점과 clipping을 실제 픽셀로 검사합니다. 공개 API·제품 수·기본값은
`0.2.0-rc.1`과 같습니다.

## 정리

- 임시 진단 테스트와 metric print를 제거했습니다.
- 테스트의 중복 RGBA 디코더 8개를 한 함수로 통합했습니다. 디코딩 실패는 assertion으로 드러납니다.
- 분필 loss-mask 계산은 기존 painter의 구현을 공유합니다.
- 오래된 실패 안내는 이 문서로 대체해 사용 안내의 중복 상태 설명을 제거했습니다.
- 추가 외부 의존성·GitHub Actions·배포 자동화는 없습니다.

## 최종 검증

환경: macOS 27.0.1, Xcode 27.2, Swift 6.4.2,
iOS 26.5 iPhone 17 Pro Max Simulator.

| 검사 | 결과 |
|---|---|
| macOS Debug 전체 | XCTest 491개 + Swift Testing 14개 통과 |
| macOS Release 전체 | XCTest 491개 + Swift Testing 14개 통과 |
| iOS Debug 전체 | XCTest 566개 + Swift Testing 13개 통과 |
| iOS Release 전체 | XCTest 566개 + Swift Testing 13개 통과 |
| macOS Release 패키지·데모 빌드 | 통과 |
| 13개 공개 제품 외부 소비자 iOS Release 빌드 | 통과, iOS 16 배포 대상, 일반 Release 설정 |
| iOS 샘플 UI | 9개 route·재생 control 검사 2개 통과 |
| 자격증명 패턴 검사 | 후보 파일 259개에서 발견되지 않음 |

macOS의 iOS 전용 target에 테스트가 없는 것은 실행 성공 개수에 더하지 않습니다.
실행한 테스트의 skip은 관찰되지 않았습니다. 민감정보 패턴 검사는 독립 보안 감사를
뜻하지 않으며, 실제 기기의 FPS·전력·VoiceOver와 Linux runtime은 이번 검증 범위에
포함되지 않습니다.

명령은 [사용 안내](README.md#검사와-보존-계약)를 따릅니다. Release iOS 검사는
`-configuration Release ENABLE_TESTABILITY=YES`를 추가합니다.
로컬 근거 로그는 `/tmp/livetext-stable-full-{mac,ios}.log`,
`/tmp/livetext-stable-release-tests-{mac,ios}.log`,
`/tmp/livetext-stable-release-{mac,ios}.log`, `/tmp/livetext-stable-sample-ui.log`입니다.
이 실행 로그는 GitHub 배포물에 포함되지 않습니다.

## 설치와 권리

```swift
.package(url: "https://github.com/axiom-orient/LiveText.git", exact: "0.2.0")
```

13개 제품의 목록과 실제 사용 경로는 [사용 안내](README.md)를 확인하세요.
`0.1.0`에는 복원된 모든 제품이 없으므로 모든 소비자의 대체 pin으로 간주하지 않습니다.

기존 `Copyright © Axient Inc.` 표시를 유지하며 프로젝트 전체를 MIT로 재허가하지
않았습니다. PNG의 소유자 제작 확인과 외부 코드 고지는
[THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)에 유지합니다.
