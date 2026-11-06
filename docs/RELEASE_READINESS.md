# 공개 배포 검토 — 0.2.1

2026-11-06, `main`의 `9e3a70de76d26812cd804f09c34eecb72d4c3746`을 기준으로
macOS·iOS 전체 테스트를 Debug·Release 각각 다시 실행했습니다.

## 패치 범위와 버전 결정

`0.2.0` 이후 검증 기준 `9e3a70d`까지의 변경은 다음 두 커밋입니다.

- `1cddd8a`: 기존 SVG 검사에 중첩 path와 잘못된 단위·쉼표 입력을 보강하고 두 importer를 확인합니다.
- `9e3a70d`: 통합 전 폴더를 기준으로 한 표현과 중복 사용 안내를 정리합니다.

릴리스 준비에서는 버전 표기와 이 검증 문서만 추가로 갱신합니다.

제품 소스, 리소스, `Package.swift`, 샘플·데모와 실행 스크립트는 `0.2.0`과
byte 단위로 같습니다. 공개 API·13개 library product·최소 OS·기본값과 데이터
해석 규칙을 변경하지 않습니다. 이 범위에 맞춰 `0.2.1` 패치 버전을 사용합니다.
기존 `0.2.0` 태그와 릴리스는 그대로 보존합니다.

`0.2.0`에 포함된 분필 합성·snapshot 출력 수정은 유지합니다.
해당 원인과 수정 기록은 [0.2.0 배포 검토](https://github.com/axiom-orient/LiveText/blob/0.2.0/docs/RELEASE_READINESS.md)를 참고하세요.

## 재검증 결과

환경: macOS 27.0.1, Xcode 27.2, Swift 6.4.2,
iOS 26.5 iPhone 17 Pro Max Simulator.

| 플랫폼 | Debug 전체 | Release 전체 |
|---|---|---|
| macOS | XCTest 491개 + Swift Testing 14개 통과 | XCTest 491개 + Swift Testing 14개 통과 |
| iOS | XCTest 566개 + Swift Testing 13개 통과 | XCTest 566개 + Swift Testing 13개 통과 |

샘플 앱의 9개 route·재생 control을 확인하는 UI 검사 2개도 다시 통과했습니다.
로그는 `/tmp/livetext-021-sample-ui.log`입니다.

실패·skip은 0입니다. 검사 기준·허용 범위·제품 코드를 바꾸지 않았습니다.
macOS에서 iOS 전용 테스트가 없는 target은 실행 개수에 더하지 않습니다.

실행 명령은 [사용 안내](README.md#검사와-보존-계약)를 따릅니다.
iOS Release 테스트는 최적화를 유지하면서 `@testable` 접근을 허용하도록
`-configuration Release ENABLE_TESTABILITY=YES`를 사용합니다.
로컬 실행 로그는 `/tmp/livetext-021-macos-{debug,release}.log`와
`/tmp/livetext-021-ios-{debug,release}.log`입니다.
이 로그는 GitHub 배포물에 포함하지 않습니다.

실제 기기의 FPS·전력·VoiceOver와 Linux runtime은 이번 검증 범위에 포함하지 않습니다.
이전 버전의 관측을 이번 실행 결과로 합산하지 않습니다.

## 배포 계약

```swift
.package(url: "https://github.com/axiom-orient/LiveText.git", exact: "0.2.1")
```

일반 Release 설정의 별도 소비자에서 13개 제품의 연결·빌드와 공개 API를 검사합니다.
게시 후에는 GitHub의 exact 버전을 직접 받아 `Package.resolved`의 버전·커밋을
태그와 대조하고 실제 snapshot 출력도 확인합니다. 설치 확인 결과는 GitHub 릴리스
설명에 기록합니다.

기존 Axient Inc. 권리 표시와 [외부 코드·리소스 고지](../THIRD_PARTY_NOTICES.md)는
변경하지 않습니다. 추가 의존성·GitHub Actions·배포 자동화는 없습니다.
복구가 필요하면 소비자의 pin을 기존 `0.2.0`으로 되돌릴 수 있습니다.
