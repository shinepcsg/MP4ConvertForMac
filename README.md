# MP4 영상 압축기

macOS에서 실행되는 SwiftUI 기반 MP4 압축 유틸리티입니다. 외부 `ffmpeg` 없이 macOS 기본 `AVFoundation`으로 MP4를 다시 내보냅니다.

## 기능

- MP4 입력 파일 선택
- 출력 MP4 저장 위치 선택
- 소리 제거 또는 원본 오디오 유지
- 원본 유지, 최대 1080p, 최대 720p, 최대 480p, 사용자 지정 화면 크기
- 화질 우선, 균형, 용량 우선 비트레이트 기반 압축
- 원본, 30fps, 24fps, 15fps 출력 프레임 제한
- 변환 진행률 표시와 Finder에서 결과 확인

## 실행

```bash
./run.sh
```

루트의 `run.sh`, `build.sh`, `build_app.sh`는 편의를 위한 바로가기 스크립트입니다. 실제 명령은 `Scripts/` 폴더 안의 같은 이름 스크립트에 들어 있습니다.

## 릴리스용 앱 번들 생성

```bash
./build_app.sh
```

생성 결과는 `dist/MP4ConvertorApp.app`에 저장됩니다.

## 빌드만 확인

```bash
./build.sh
```

`build.sh`는 Swift 실행 파일만 컴파일해서 `.build/release/MP4ConvertorApp`를 만드는 확인용 빌드입니다. `build_app.sh`는 같은 릴리스 빌드를 먼저 수행한 뒤, 실행 파일과 `Support/Info.plist`를 묶어 Finder에서 실행할 수 있는 `dist/MP4ConvertorApp.app` 앱 번들을 만듭니다.

## 요구 사항

- macOS 14 이상
- Swift 6 또는 Xcode Command Line Tools

## 동작 방식

앱은 입력 MP4의 영상 트랙을 읽고 선택한 화면 크기에 맞춰 비율을 유지한 상태로 축소합니다. `소리 제거`가 켜져 있으면 오디오 트랙을 출력하지 않습니다. 영상은 `AVAssetReader`와 `AVAssetWriter`로 H.264 재인코딩하며, 선택한 화질 옵션과 출력 해상도/FPS/원본 추정 비트레이트를 기준으로 목표 비트레이트를 계산합니다. 오디오를 유지하는 경우 AAC로 다시 인코딩해 불필요한 용량 증가를 줄입니다. v2 UI에서는 입력 파일을 고르면 예상 출력 해상도, 출력 FPS, 목표 영상 비트레이트가 화면에 표시됩니다.

프레임 제한 옵션은 출력 FPS를 낮춰 중간 프레임을 재샘플링하는 방식입니다. 움직임이 적거나 공유용으로 쓰는 영상은 24fps 또는 15fps를 선택하면 같은 해상도에서도 파일 크기를 더 줄일 수 있습니다.
