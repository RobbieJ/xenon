#!/bin/sh
# Xcode Cloud runs this after cloning, before resolving dependencies and building.
# 1. Regenerate the Xcode project from project.yml so the committed project can never drift.
# 2. Run the SottoKit unit tests here (they are Swift Package tests, which Xcode Cloud's
#    test action does not run on their own); a failure fails the build.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Installing XcodeGen"
brew install xcodegen >/dev/null

echo "Generating Sotto.xcodeproj"
xcodegen generate --quiet

echo "Running SottoKit tests"
( cd Packages/SottoKit && swift test --parallel )
