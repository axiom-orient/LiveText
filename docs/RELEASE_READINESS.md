# 공개 배포 검토 — 0.2.0-rc.1

2026-11-06 기준 **검토용 공개 배포**입니다. 안정판으로 판정하지 않습니다.
빌드·공개 제품 연결과 아래 기능 검사는 확인했지만, 분필 bitmap 비교 실패가
남아 있습니다. 실패 검사를 제외하거나 허용 범위를 늘리지 않았습니다.

## 변경과 보존 경계

- 줄바꿈의 중복 chunk 순회를 한 내부 함수로 통합했습니다.
- 분필 texture loss pass의 filter 상태가 다음 pass로 누출되는 문제를 고쳤습니다.
- 로컬 원본의 13개 library product와 flow 선택 API를 공개 패키지에 복원했습니다.
  기존 공개 버전의 magazine·dry-brush 기본값과 로컬 원본의 inline·fine-line 기본값은
  서로 다르므로 구분했습니다. 공개 버전의 기본값은 유지합니다.
- 폭만 받는 inline 배치에서 magazine 최소 폭이 적용되던 문제를 고쳤습니다.
- 저장된 준비 데이터는 현재 내용 검증과 알려진 두 digest domain을 검증하고
  원래 revision을 보존합니다. 검증할 수 없는 custom-limit 데이터는 거부합니다.
- SVG의 디코딩 검증 우회, 도형 내부 중첩, 단위가 붙은 scalar를 거부합니다.
  평면 artwork 모델이 정확히 합성할 수 없는 부분 group/object opacity도 거부합니다.
- 재질 예산은 양수 요청에만 분배합니다. 색연필 부분 샘플링은 공유하는 안전한
  보간으로 극단적인 유한 좌표의 overflow 중단을 방지합니다.
- SwiftUI snapshot 출력 크기를 실제로 고정하고 좌상단 기준으로 자릅니다.
  요청 크기 검증 뒤 콘텐츠의 고정 크기가 출력 raster 한도를 우회하던 문제를 고쳤습니다.
- append, 손글씨 재생, snapshot 교체·취소, Dust raster·입자·Metal 자원의
  기존 회귀 검사를 공개 패키지에서 다시 실행하도록 연결했습니다.

추가 외부 의존성은 없습니다. GitHub Actions·배포 자동화는 추가하지 않았습니다.
공개 package API의 제거는 관찰되지 않았습니다. 이전 공개 태그와 원본 13개 모듈의
API 비교 및 별도 소비자에서의 제품 import·생성 호출을 확인했습니다.
이 검사는 모든 외부 앱과 저장 데이터의 호환성을 보증하지 않습니다.

## 최종 검증

소스 기준 커밋: `e4919e6783e49d0217c7a676ac7b08e7cc74804c`.
이후 릴리스 문서 변경은 제품 소스를 바꾸지 않습니다.
환경: macOS 27.0.1, Xcode 27.2, iOS 26.5 iPhone 17 Pro Max Simulator.

| 검사 | 결과 |
|---|---|
| macOS Release 전체 빌드·데모 | 통과 |
| 13개 공개 제품을 연결한 외부 소비자의 iOS Release 빌드 | 통과, iOS 16 배포 대상 |
| macOS 전체 XCTest | 489개 실행, 2개 test case에서 assertion 3개 실패 |
| macOS Swift Testing | 14개 통과 |
| iOS 전체 XCTest | 564개 실행, 1개 test case에서 assertion 4개 실패 |
| iOS Swift Testing | 13개 통과 |
| iOS 샘플 UI | 9개 route·재생 control 검사 2개 통과; 이후 소스 변경 전 실행 |
| 자격증명 패턴·개인 서명 파일·25 MiB 초과 파일 | 추적 파일 257개에서 발견되지 않음 |

macOS의 DustKit·Presentation iOS 전용 검사가 0개인 것은 실행 성공으로 합산하지 않습니다.
Metal 검사는 shader library·pipeline·texture·particle metadata의 실제 생성을
확인했으며 전체 GPU frame 표시·실기기 FPS 인증을 뜻하지 않습니다.
민감정보 검사는 알려진 키 패턴과 파일명 검사이며 독립 보안 감사를 뜻하지 않습니다.

검증 명령은 [사용 안내](README.md#검사와-보존-계약)를 참고하세요.
로컬 실행 로그는 `livetext-release-final-mac.log`, `livetext-release-final-ios.log`,
`livetext-release-build-mac.log`, `livetext-release-consumer-ios.log`로 `/tmp`에 남겼습니다.
이 파일들은 GitHub 배포물에 포함되지 않습니다.

## 알려진 실패와 불확실성

| 환경·검사 | 관찰 |
|---|---|
| macOS `testChalkSurfaceViewAndPainterShareTexturedEdgeCoverage` | View와 painter의 외곽 weighted alpha 합 차이 305; 허용 192 및 10% 초과 |
| iOS `testDepositedGrainDoesNotMoveAsTheFrontAdvances` | 진행률 증가 전후 기존 영역의 네 픽셀이 채널별 1/255 차이 |
| macOS `testPublicChalkFacadeAndLiveTextPainterUseCanonicalConfiguration` | 전체 실행에서 같은 설정의 반복 결과가 14픽셀 차이; 단독 재실행은 통과 |

세 결과의 원인은 `[UNKNOWN]`입니다. 단독 재실행 통과를 수정 완료로 처리하지 않습니다.
이 차이에 민감한 용도는 후보 버전의 실제 출력으로 판단해야 합니다.
실제 기기의 GPU frame·에너지·최대 메모리, VoiceOver, Linux runtime,
모든 폰트·RTL·OS별 adaptive glyph 조합은 이번 최종 검증 범위에 포함되지 않습니다.

## 권리와 설치

기존 `Copyright © Axient Inc.` 표시를 유지합니다. 프로젝트 전체를 MIT로
재허가하지 않았습니다. PNG는 소유자가 ChatGPT로 직접 제작했다고 확인했습니다.
적용되는 외부 코드의 필수 고지는 [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)에 유지합니다.

```swift
.package(url: "https://github.com/axiom-orient/LiveText.git", exact: "0.2.0-rc.1")
```

다른 revision을 쓰던 소비자는 기존 package pin을 보관하고 후보를 검증하세요.
되돌릴 때는 원래 pin으로 복원합니다. 구형 `0.1.0`에는 이번에 복원한 모든 제품이
없으므로 모든 소비자의 대체 버전으로 간주하지 않습니다.
