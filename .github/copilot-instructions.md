# Copilot Instructions

- 모든 사용자-facing 문구와 문서는 한국어로 작성한다.
- 이 프로젝트는 macOS SwiftUI와 AVFoundation 기반 MP4 압축 유틸리티다.
- 외부 ffmpeg 의존성을 추가하지 않는다.
- 영상 변환은 `AVAssetReader`/`AVAssetWriter` 기반 비트레이트 제어 파이프라인을 유지한다.
- Swift Package 구조를 유지하고 `Scripts/build.sh`, `Scripts/run.sh`, `Scripts/build_app.sh`로 검증한다.
