FROM swift:5.9-jammy
# FROM swiftlang/swift:nightly-main-focal

# Install test dependencies
RUN DEBIAN_FRONTEND=noninteractive \
  apt-get update && \
  apt-get install -y \
    xxd

# Install swift-format
RUN \
  git clone https://github.com/apple/swift-format.git -b 509.0.0 /opt/swift-format && \
  cd /opt/swift-format && \
  # Build debug since release takes forever to build and there isn't a meaningful runtime performance delta
  swift build -c debug && \
  cp .build/debug/swift-format /usr/bin/swift-format && \
  rm -rf /opt/swift-format
  