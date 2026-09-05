#!/bin/bash

set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIRECTORY"

unset PRIVATEAI_RUN_EXECUTOR_DIAGNOSTICS
unset PRIVATEAI_RUN_HEADLESS_MODEL_EVALS
unset PRIVATEAI_RUN_LIVE_WEB_TESTS
unset PRIVATEAI_RUN_LIVE_MATH_E2E
unset PRIVATEAI_RUN_PRODUCTION_ACCEPTANCE

swift test --package-path Packages/ExecutionKit
swift test --package-path Packages/LLMCore
swift test --package-path Packages/PrivateAITools
xcodebuild test \
  -project "Private AI/Private AI.xcodeproj" \
  -scheme "Private AI" \
  -destination 'platform=macOS' \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'Private AITests'